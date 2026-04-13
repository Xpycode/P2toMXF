import Foundation

extension ConversionViewModel {

    // MARK: - Conversion

    func startConversion() {
        guard let outputDir = settings.outputDirectory else {
            errorMessage = "Please select an output directory"
            return
        }

        let clipsToProcess = sortedSelectedClips
        guard !clipsToProcess.isEmpty else {
            errorMessage = "No clips selected"
            return
        }

        isCancelled = false
        isConverting = true
        let ext = settings.outputContainer.fileExtension

        switch settings.processingMode {
        case .concatenate:
            startConcatenateConversion(clips: clipsToProcess, outputDir: outputDir, ext: ext)
        case .individual:
            startIndividualConversion(clips: clipsToProcess, outputDir: outputDir, ext: ext)
        }
    }

    private func startConcatenateConversion(clips: [P2Clip], outputDir: URL, ext: String) {
        let groups = fullySelectedGroups
        let groupCount = groups.count
        let totalClips = groups.reduce(0) { $0 + $1.clipCount }

        log("Starting merge of \(groupCount) group(s) to \(ext.uppercased())")
        log("Output directory: \(outputDir.path)")
        log("FFmpeg path: \(ffmpeg.ffmpegPath?.path ?? "NOT FOUND")")

        // Mark all clips in selected groups as pending
        for group in groups {
            for clip in group.clips {
                conversionStatus[clip.id] = .pending
            }
        }

        // Start progress timer
        startProgressTimer(totalClips: totalClips)

        Task {
            defer { stopProgressTimer() }

            var successCount = 0
            var failCount = 0

            for (groupIdx, group) in groups.enumerated() {
                // Check for cancellation before starting each group
                if isCancelled {
                    log("Cancellation requested, stopping...")
                    break
                }

                // Build output filename with numeric suffix if multiple groups
                let suffix = groupCount > 1 ? String(format: "_%02d", groupIdx + 1) : ""
                let outputName = "\(effectiveOutputFilename)\(suffix).\(ext)"
                let outputURL = outputDir.appendingPathComponent(outputName)

                log("--- Group \(group.groupIndex) (\(group.clipCount) clips) ---")
                log("Output: \(outputName)")
                log("Clips:")
                for (i, clip) in group.clips.enumerated() {
                    log("  \(i + 1). \(clip.displayName) [TC: \(clip.startTimecode)]")
                }

                // Mark clips in this group as in progress
                for clip in group.clips {
                    conversionStatus[clip.id] = .inProgress(progress: 0)
                }

                do {
                    // Update phase for this group
                    progressMetrics.phase = "Group \(groupIdx + 1)/\(groupCount): \(group.clipCount) clips"
                    progressMetrics.currentClipIndex = groupIdx + 1

                    try await ffmpeg.mergeClips(group.clips, to: outputURL, settings: settings) { progress, status in
                        Task { @MainActor in
                            for clip in group.clips {
                                self.conversionStatus[clip.id] = .inProgress(progress: progress)
                            }
                            // Update phase with current status
                            self.progressMetrics.phase = status
                            self.progressMetrics.progress = progress
                        }
                    } logHandler: { message in
                        Task { @MainActor in
                            self.log(message)
                        }
                    } metricsHandler: { metrics in
                        Task { @MainActor in
                            self.updateMetrics(metrics)
                        }
                    }

                    // Check if cancelled during conversion
                    if isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    } else {
                        // Brief finalizing state for cleanup phase
                        for clip in group.clips {
                            conversionStatus[clip.id] = .finalizing
                        }
                        progressMetrics.phase = "Finalizing \(outputName)..."

                        // Small delay to show finalizing state (cleanup happens here)
                        try? await Task.sleep(for: .milliseconds(200))

                        for clip in group.clips {
                            conversionStatus[clip.id] = .completed
                        }
                        log("SUCCESS: Created \(outputName)")
                        successCount += 1
                    }

                } catch is CancellationError {
                    // Swift Task.checkCancellation() throws CancellationError
                    for clip in group.clips {
                        conversionStatus[clip.id] = .pending
                    }
                    log("Cancelled before completing \(group.clipCount) clips")
                    break
                } catch let error as FFmpegWrapper.FFmpegError {
                    // Check if it's a cancellation
                    if case .cancelled = error {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                        break
                    }
                    // Other FFmpeg errors
                    if !isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        }
                        log("FAILED: \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    }
                } catch {
                    // Don't show error if cancelled
                    if !isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        }
                        log("FAILED: \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    }
                }
            }

            if isCancelled {
                log("Conversion cancelled")
            } else {
                log("Merge complete: \(successCount) group(s) succeeded, \(failCount) failed")
            }
            isConverting = false
        }
    }

    private func startIndividualConversion(clips: [P2Clip], outputDir: URL, ext: String) {
        log("Starting individual conversion of \(clips.count) clips to \(ext.uppercased())")
        log("Output directory: \(outputDir.path)")

        // Mark all clips as pending
        for clip in clips {
            conversionStatus[clip.id] = .pending
        }

        // Start progress timer
        startProgressTimer(totalClips: clips.count)

        Task {
            defer { stopProgressTimer() }

            var successCount = 0
            var failCount = 0

            for (index, clip) in clips.enumerated() {
                // Check for cancellation before starting each clip
                if isCancelled {
                    log("Cancellation requested, stopping...")
                    break
                }

                let outputName = "\(clip.displayName).\(ext)"
                let outputURL = outputDir.appendingPathComponent(outputName)

                log("[\(index + 1)/\(clips.count)] Converting \(clip.displayName)...")
                conversionStatus[clip.id] = .inProgress(progress: 0)

                // Update phase for this clip
                progressMetrics.phase = "Clip \(index + 1)/\(clips.count): \(clip.displayName)"
                progressMetrics.currentClipIndex = index + 1

                do {
                    try await ffmpeg.rewrapSingleClip(clip, to: outputURL, outputFormat: ext, settings: settings) { progress, status in
                        Task { @MainActor in
                            self.conversionStatus[clip.id] = .inProgress(progress: progress)
                            // Calculate overall progress across all clips
                            let overallProgress = (Double(index) + progress) / Double(clips.count)
                            self.progressMetrics.progress = overallProgress
                            self.progressMetrics.phase = status.isEmpty ? "Clip \(index + 1)/\(clips.count)" : status
                        }
                    } logHandler: { message in
                        Task { @MainActor in
                            self.log(message)
                        }
                    } metricsHandler: { metrics in
                        Task { @MainActor in
                            // Adjust progress for overall clip context
                            var adjusted = metrics
                            adjusted.progress = (Double(index) + metrics.progress) / Double(clips.count)
                            adjusted.currentClipIndex = index + 1
                            self.updateMetrics(adjusted)
                        }
                    }

                    // Check if cancelled during conversion
                    if isCancelled {
                        conversionStatus[clip.id] = .pending
                    } else {
                        // Brief finalizing state for cleanup phase
                        conversionStatus[clip.id] = .finalizing
                        progressMetrics.phase = "Finalizing \(outputName)..."

                        // Small delay to show finalizing state
                        try? await Task.sleep(for: .milliseconds(200))

                        conversionStatus[clip.id] = .completed
                        log("SUCCESS: Created \(outputName)")
                        successCount += 1
                    }

                } catch is CancellationError {
                    // Swift Task.checkCancellation() throws CancellationError
                    conversionStatus[clip.id] = .pending
                    log("Cancelled during \(clip.displayName)")
                    break
                } catch let error as FFmpegWrapper.FFmpegError {
                    // Check if it's a cancellation
                    if case .cancelled = error {
                        conversionStatus[clip.id] = .pending
                        break
                    }
                    // Other FFmpeg errors
                    if !isCancelled {
                        conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        log("FAILED: \(clip.displayName) - \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        conversionStatus[clip.id] = .pending
                    }
                } catch {
                    // Don't show error if cancelled
                    if !isCancelled {
                        conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        log("FAILED: \(clip.displayName) - \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        conversionStatus[clip.id] = .pending
                    }
                }
            }

            if isCancelled {
                log("Conversion cancelled")
            } else {
                log("Conversion complete: \(successCount) succeeded, \(failCount) failed")
            }
            isConverting = false
        }
    }

    func cancelConversion() {
        isCancelled = true
        ffmpeg.cancelConversion()
        isConverting = false
        log("Conversion cancelled by user")
    }

    // MARK: - Queue Integration

    /// Adds the current selection to the batch queue
    /// - Parameters:
    ///   - autoStart: If true, immediately starts queue processing (for "Convert Now")
    /// - Returns: True if successfully added, false if validation failed
    @discardableResult
    func addToQueue(autoStart: Bool = false) -> Bool {
        guard let card = p2Card else {
            errorMessage = "No P2 card loaded"
            return false
        }

        guard let outputDir = settings.outputDirectory else {
            errorMessage = "Please select an output directory"
            return false
        }

        switch settings.processingMode {
        case .concatenate:
            return addConcatenateJobsToQueue(card: card, outputDir: outputDir, autoStart: autoStart)
        case .individual:
            return addIndividualJobToQueue(card: card, outputDir: outputDir, autoStart: autoStart)
        }
    }

    /// Adds concatenate jobs to queue (one per fully selected group)
    private func addConcatenateJobsToQueue(card: P2Card, outputDir: URL, autoStart: Bool) -> Bool {
        let groups = fullySelectedGroups
        guard !groups.isEmpty else {
            errorMessage = "No groups fully selected for merging"
            return false
        }

        guard !effectiveOutputFilename.isEmpty else {
            errorMessage = "Please enter an output filename"
            return false
        }

        let ext = settings.outputContainer.fileExtension
        let queueManager = QueueManager.shared

        for (index, group) in groups.enumerated() {
            // Build output filename with numeric suffix if multiple groups
            let suffix = groups.count > 1 ? String(format: "_%02d", index + 1) : ""
            let outputName = "\(effectiveOutputFilename)\(suffix).\(ext)"
            let outputURL = outputDir.appendingPathComponent(outputName)

            // Only autoStart on the first job (to trigger queue processing)
            let shouldAutoStart = autoStart && index == 0
            queueManager.addJob(
                cardName: card.name,
                cardPath: card.rootPath,
                clips: group.clips,
                settings: settings,
                destinationURL: outputURL,
                autoStart: shouldAutoStart
            )
        }

        let jobCount = groups.count
        if autoStart {
            queueFeedback = "Started \(jobCount) job\(jobCount == 1 ? "" : "s")"
        } else {
            queueFeedback = "Added \(jobCount) job\(jobCount == 1 ? "" : "s") to queue"
        }

        // Auto-clear after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            queueFeedback = nil
        }

        return true
    }

    /// Adds an individual files job to queue
    private func addIndividualJobToQueue(card: P2Card, outputDir: URL, autoStart: Bool) -> Bool {
        let clips = sortedSelectedClips
        guard !clips.isEmpty else {
            errorMessage = "No clips selected"
            return false
        }

        let queueManager = QueueManager.shared

        // For individual mode, destination is the directory
        queueManager.addJob(
            cardName: card.name,
            cardPath: card.rootPath,
            clips: clips,
            settings: settings,
            destinationURL: outputDir,
            autoStart: autoStart
        )

        let clipCount = clips.count
        if autoStart {
            queueFeedback = "Started job (\(clipCount) clip\(clipCount == 1 ? "" : "s"))"
        } else {
            queueFeedback = "Added job (\(clipCount) clip\(clipCount == 1 ? "" : "s")) to queue"
        }

        // Auto-clear after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            queueFeedback = nil
        }

        return true
    }

    /// Whether a job can be added to the queue (same validation as canConvert)
    var canAddToQueue: Bool {
        canConvert
    }
}
