import Foundation

extension QueueManager {

    // MARK: - Queue Processing

    /// Main loop that processes jobs sequentially
    func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        preventSleep()

        log("=== Queue processing started ===")

        while let nextJob = jobs.first(where: { $0.status == .pending }) {
            await processJob(nextJob)
            saveQueue()
        }

        allowSleep()
        isProcessing = false
        log("=== Queue processing complete ===")
        saveQueue()
    }

    /// Processes a single job
    func processJob(_ job: ConversionJob) async {
        guard jobIndex(for: job.id) != nil else { return }
        let jobId = job.id

        currentJobId = jobId
        updateJob(jobId) { j in
            j.status = .preparing
            j.progress = 0
            j.startedAt = Date()
        }

        // Calculate and store estimate
        currentJobEstimate = speedTracker.estimateJob(job)

        log("--- Starting job: \(job.displayName) ---")
        log("Card: \(job.cardName)")
        log("Clips: \(job.clips.count)")
        log("Output: \(job.destinationURL.path)")
        if let estimate = currentJobEstimate {
            log("Estimated time: \(estimate.formattedEstimate) (\(estimate.formattedSpeed))")
        }

        // Resolve bookmarks and start security-scoped access.
        // IMPORTANT: Only copy back the bookmark-related fields that `resolve*Bookmark()`
        // may mutate — never assign the whole struct, which would clobber `status`,
        // `startedAt`, and `progress` set by the preparing update above.
        var mutableJob = job
        let cardURL: URL
        if let resolvedCardURL = mutableJob.resolveCardBookmark() {
            cardURL = resolvedCardURL
            updateJob(jobId) { j in
                j.cardBookmarkData = mutableJob.cardBookmarkData
                j.cardPath = mutableJob.cardPath
            }
        } else {
            cardURL = job.cardPath
        }

        let outputDirURL: URL
        if let resolvedOutputURL = mutableJob.resolveOutputBookmark() {
            outputDirURL = resolvedOutputURL
            updateJob(jobId) { j in
                j.outputBookmarkData = mutableJob.outputBookmarkData
            }
        } else {
            outputDirURL = job.destinationURL.deletingLastPathComponent()
        }

        // Start security-scoped access using balanced tracking to prevent nested start/stop issues
        let cardAccess = startAccessingIfNeeded(cardURL)
        let outputAccess = startAccessingIfNeeded(outputDirURL)

        // Fail fast with clear error if access denied
        if cardAccess == .denied {
            updateJob(jobId) { $0.status = .failed("Cannot access source folder - permission denied or bookmark expired") }
            log("FAILED: Cannot access source folder for \(job.displayName)")
            currentJobId = nil
            currentJobEstimate = nil
            return
        }

        if outputAccess == .denied {
            updateJob(jobId) { $0.status = .failed("Cannot access output folder - permission denied or bookmark expired") }
            log("FAILED: Cannot access output folder for \(job.displayName)")
            currentJobId = nil
            currentJobEstimate = nil
            return
        }

        // Only stop access we actually started (not access that was already active)
        defer {
            if cardAccess == .newlyGranted {
                stopAccessingIfNeeded(cardURL)
            }
            if outputAccess == .newlyGranted {
                stopAccessingIfNeeded(outputDirURL)
            }
        }

        // Preflight: fail fast if there isn't enough free space on the temp or output volume.
        let tempDir = TempDirectoryManager.shared.effectiveTempDirectory
        if let spaceError = preflightDiskSpaceError(for: job, tempDir: tempDir, outputDir: outputDirURL) {
            updateJob(jobId) { $0.status = .failed(spaceError) }
            log("FAILED preflight: \(spaceError)")
            currentJobId = nil
            currentJobEstimate = nil
            return
        }
        log("Preflight OK — \(preflightSummary(for: job, tempDir: tempDir, outputDir: outputDirURL))")

        let startTime = Date()
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let contentDuration = Double(job.totalDurationFrames) / fps

        do {
            updateJob(jobId) { $0.status = .active }

            var outputFiles: [URL] = []
            switch job.settings.processingMode {
            case .concatenate:
                outputFiles = try await processConcatenateJob(job, jobId: jobId)
            case .individual:
                outputFiles = try await processIndividualJob(job, jobId: jobId)
            }

            // Store actual output URLs for verification
            // (may differ from expected due to conflict resolution)
            updateJob(jobId) { j in
                j.actualOutputURLs = outputFiles
                j.status = .completed
                j.progress = 1.0
            }

            // Generate conversion report if enabled
            if job.settings.generateReport {
                do {
                    let reportURL = try await ReportGenerator.generateReport(
                        for: job,
                        outputFiles: outputFiles,
                        includeChecksum: job.settings.includeChecksum
                    )
                    log("Report saved: \(reportURL.lastPathComponent)")
                } catch {
                    log("Warning: Failed to generate report - \(error.localizedDescription)")
                }
            }

            // Record the conversion speed for future estimates
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                speedTracker.recordConversion(
                    bytesProcessed: totalBytes,
                    durationSeconds: elapsed,
                    contentDurationSeconds: contentDuration,
                    processingMode: job.settings.processingMode,
                    outputFormat: job.settings.outputContainer
                )

                let speedMultiplier = contentDuration / elapsed
                log("SUCCESS: \(job.displayName) - \(String(format: "%.1fx", speedMultiplier)) realtime")
            } else {
                log("SUCCESS: \(job.displayName)")
            }

        } catch {
            // Check if cancelled vs actual error
            if let idx = jobIndex(for: jobId), jobs[idx].status == .cancelled {
                log("Job cancelled: \(job.displayName)")
            } else {
                updateJob(jobId) { $0.status = .failed(error.localizedDescription) }
                log("FAILED: \(job.displayName) - \(error.localizedDescription)")
            }
        }

        // Clear job-specific state
        currentJobId = nil
        currentJobEstimate = nil
        slowSpeedWarning = nil
    }

    /// Processes a concatenation job (multiple clips -> single file)
    /// - Returns: Array containing the single output file URL
    func processConcatenateJob(_ job: ConversionJob, jobId: UUID) async throws -> [URL] {
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let totalDuration = Double(job.totalDurationFrames) / fps

        try await ffmpeg.mergeClips(
            job.clips,
            to: job.destinationURL,
            settings: job.settings
        ) { [weak self] progress, message in
            Task { @MainActor in
                self?.updateJob(jobId) { $0.progress = progress }
            }
        } logHandler: { [weak self] message in
            Task { @MainActor in
                self?.log(message)
            }
        } metricsHandler: { [weak self] metrics in
            Task { @MainActor in
                self?.checkForSlowSpeed(
                    metrics: metrics,
                    totalBytes: totalBytes,
                    totalDuration: totalDuration,
                    outputPath: job.destinationURL
                )
            }
        }

        return [job.destinationURL]
    }

    /// Processes an individual files job (each clip -> separate file)
    /// - Returns: Array of all output file URLs created
    func processIndividualJob(_ job: ConversionJob, jobId: UUID) async throws -> [URL] {
        let outputDir = job.destinationURL
        let ext = job.settings.outputContainer.fileExtension
        var outputFiles: [URL] = []

        // Calculate totals for slow speed detection
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let totalDuration = Double(job.totalDurationFrames) / fps

        for (clipIndex, clip) in job.clips.enumerated() {
            // Check if job was cancelled (re-derive index safely)
            if let idx = jobIndex(for: jobId), jobs[idx].status != .active {
                throw NSError(domain: "QueueManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Job cancelled"])
            }

            // Resolve filename conflicts for individual clip outputs
            var clipOutputURL = outputDir.appendingPathComponent("\(clip.displayName).\(ext)")
            clipOutputURL = resolveFilenameConflict(for: clipOutputURL)
            log("[\(clipIndex + 1)/\(job.clips.count)] Converting \(clip.displayName)...")

            try await ffmpeg.rewrapSingleClip(
                clip,
                to: clipOutputURL,
                outputFormat: ext,
                settings: job.settings
            ) { [weak self] progress, _ in
                Task { @MainActor in
                    // Calculate overall progress for this job
                    let baseProgress = Double(clipIndex) / Double(job.clips.count)
                    let clipContribution = progress / Double(job.clips.count)
                    self?.updateJob(jobId) { $0.progress = baseProgress + clipContribution }
                }
            } logHandler: { [weak self] message in
                Task { @MainActor in
                    self?.log(message)
                }
            } metricsHandler: { [weak self] metrics in
                Task { @MainActor in
                    // Adjust metrics progress to account for multi-clip processing
                    var adjustedMetrics = metrics
                    let baseProgress = Double(clipIndex) / Double(job.clips.count)
                    let clipContribution = metrics.progress / Double(job.clips.count)
                    adjustedMetrics.progress = baseProgress + clipContribution

                    self?.checkForSlowSpeed(
                        metrics: adjustedMetrics,
                        totalBytes: totalBytes,
                        totalDuration: totalDuration,
                        outputPath: clipOutputURL
                    )
                }
            }

            outputFiles.append(clipOutputURL)
            log("Created: \(clipOutputURL.lastPathComponent)")
        }

        return outputFiles
    }

    // MARK: - Time Estimation

    /// Gets an estimate for a potential conversion
    func getEstimate(
        clips: [P2Clip],
        processingMode: ConversionSettings.ProcessingMode,
        outputFormat: ConversionSettings.OutputContainer
    ) -> ConversionEstimate {
        return speedTracker.estimateConversion(
            clips: clips,
            processingMode: processingMode,
            outputFormat: outputFormat
        )
    }

    /// Gets an estimate for a job
    func getEstimate(for job: ConversionJob) -> ConversionEstimate {
        return speedTracker.estimateJob(job)
    }

    /// Gets total estimate for all pending jobs
    func getTotalQueueEstimate() -> ConversionEstimate? {
        let pendingJobs = jobs.filter { $0.status == .pending }
        guard !pendingJobs.isEmpty else { return nil }

        var totalBytes: Int64 = 0
        var totalDuration: Double = 0
        var totalClips = 0

        for job in pendingJobs {
            totalBytes += job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
            let fps = job.clips.first?.frameRateDouble ?? 25.0
            totalDuration += Double(job.totalDurationFrames) / fps
            totalClips += job.clips.count
        }

        // Use first job's settings for speed estimate
        guard let firstJob = pendingJobs.first else { return nil }

        let estimate = speedTracker.estimateConversion(
            clips: pendingJobs.flatMap(\.clips),
            processingMode: firstJob.settings.processingMode,
            outputFormat: firstJob.settings.outputContainer
        )

        return estimate
    }

    /// Dismisses the slow speed warning
    func dismissSlowSpeedWarning() {
        slowSpeedWarning = nil
        speedTracker.clearSpeedWarning()
    }

    // MARK: - Preflight Disk Space Check

    /// Returns a human-readable error string if there is not enough free space to run the job,
    /// or nil if the job can safely start. Applies a 10% safety margin on top of the source size.
    /// Accounts for the case where temp and output share the same volume (doubles the requirement).
    func preflightDiskSpaceError(
        for job: ConversionJob,
        tempDir: URL,
        outputDir: URL
    ) -> String? {
        let requiredBase = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let requiredWithMargin = Int64(Double(requiredBase) * 1.10)

        let shareVolume = DiskSpace.sameVolume(tempDir, outputDir)

        if shareVolume {
            // Temp and output on same volume — we need 2x the required amount on that one disk.
            let combined = requiredWithMargin * 2
            guard let free = DiskSpace.availableCapacity(for: tempDir) else { return nil }
            if free < combined {
                let name = DiskSpace.volumeName(for: tempDir) ?? "the selected volume"
                return "Not enough space on \(name): \(DiskSpace.formatBytes(free)) free, " +
                    "~\(DiskSpace.formatBytes(combined)) required (temp + output on same volume). " +
                    "Choose a different temp folder in File → Temp Folder… to split the load."
            }
            return nil
        }

        // Separate volumes — check each independently.
        if let freeTemp = DiskSpace.availableCapacity(for: tempDir), freeTemp < requiredWithMargin {
            let name = DiskSpace.volumeName(for: tempDir) ?? "temp volume"
            return "Not enough space on \(name) (temp): \(DiskSpace.formatBytes(freeTemp)) free, " +
                "~\(DiskSpace.formatBytes(requiredWithMargin)) required. " +
                "Choose a different temp folder in File → Temp Folder…"
        }
        if let freeOut = DiskSpace.availableCapacity(for: outputDir), freeOut < requiredWithMargin {
            let name = DiskSpace.volumeName(for: outputDir) ?? "output volume"
            return "Not enough space on \(name) (output): \(DiskSpace.formatBytes(freeOut)) free, " +
                "~\(DiskSpace.formatBytes(requiredWithMargin)) required."
        }
        return nil
    }

    /// Human-readable summary of a preflight check's findings, used for console logging on success.
    /// Includes volume names, free capacity, and the required-byte estimate (source size + 10% margin).
    func preflightSummary(
        for job: ConversionJob,
        tempDir: URL,
        outputDir: URL
    ) -> String {
        let requiredBase = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let requiredWithMargin = Int64(Double(requiredBase) * 1.10)
        let needStr = DiskSpace.formatBytes(requiredWithMargin)

        let tempName = DiskSpace.volumeName(for: tempDir) ?? "temp volume"
        let outName = DiskSpace.volumeName(for: outputDir) ?? "output volume"
        let tempFreeStr = DiskSpace.availableCapacity(for: tempDir).map(DiskSpace.formatBytes) ?? "unknown"
        let outFreeStr = DiskSpace.availableCapacity(for: outputDir).map(DiskSpace.formatBytes) ?? "unknown"

        if DiskSpace.sameVolume(tempDir, outputDir) {
            return "Temp: \(tempName) (\(tempFreeStr) free), Output: same volume; need ~\(needStr)"
        }
        return "Temp: \(tempName) (\(tempFreeStr) free), Output: \(outName) (\(outFreeStr) free); need ~\(needStr)"
    }

    /// Checks current conversion speed and sets warning if significantly slow
    /// - Parameters:
    ///   - metrics: Current progress metrics from FFmpeg
    ///   - totalBytes: Total bytes being processed
    ///   - totalDuration: Total content duration in seconds
    ///   - outputPath: Output file path (for slow speed reason detection)
    func checkForSlowSpeed(
        metrics: ProgressMetrics,
        totalBytes: Int64,
        totalDuration: Double,
        outputPath: URL
    ) {
        // Parse speed multiplier from string like "12.5x"
        guard let speedStr = metrics.speed,
              let speedValue = Double(speedStr.replacingOccurrences(of: "x", with: "")) else {
            return
        }

        // Calculate remaining content based on progress
        let remainingProgress = 1.0 - metrics.progress
        let bytesRemaining = Int64(Double(totalBytes) * remainingProgress)
        let durationRemaining = totalDuration * remainingProgress

        // Check for slow speed (only after initial 10% to avoid false positives during startup)
        guard metrics.progress > 0.1 else { return }

        if let warning = speedTracker.checkSpeed(
            currentSpeedMultiplier: speedValue,
            bytesRemaining: bytesRemaining,
            contentDurationRemaining: durationRemaining,
            outputPath: outputPath
        ) {
            slowSpeedWarning = warning
        } else {
            // Clear warning if speed has recovered
            slowSpeedWarning = nil
        }
    }
}
