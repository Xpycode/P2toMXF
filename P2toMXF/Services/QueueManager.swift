import Foundation
import SwiftUI
import IOKit
import IOKit.pwr_mgt

/// Manages a queue of conversion jobs, executing them sequentially
@MainActor
class QueueManager: ObservableObject {
    // MARK: - Shared Instance
    @MainActor static let shared = QueueManager()

    // MARK: - Published State
    @Published private(set) var jobs: [ConversionJob] = []
    @Published private(set) var isProcessing = false
    @Published var consoleLog: String = ""

    // MARK: - Private
    private let ffmpeg = FFmpegWrapper()
    private let verificationService = VerificationService()
    private let speedTracker = SpeedTracker.shared
    private var currentJobId: UUID?
    private var currentVerificationJobId: UUID?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isSleepPrevented = false
    /// Tracks URLs that currently have active security-scoped access
    private var accessedSecurityScopedResources: Set<URL> = []
    @Published private(set) var isVerifying = false
    @Published private(set) var slowSpeedWarning: SlowSpeedWarning?
    @Published private(set) var currentJobEstimate: ConversionEstimate?

    // MARK: - Persistence
    private static let queueFileName = "queue.json"

    private var queueFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("P2toMXF", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        return appFolder.appendingPathComponent(Self.queueFileName)
    }

    // MARK: - Computed Properties

    /// Number of jobs waiting to be processed
    var pendingCount: Int {
        jobs.filter { $0.status == .pending }.count
    }

    /// Number of completed jobs
    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    /// Number of failed jobs
    var failedCount: Int {
        jobs.filter { if case .failed = $0.status { return true } else { return false } }.count
    }

    /// The currently active job (if any)
    var activeJob: ConversionJob? {
        jobs.first { $0.status == .active || $0.status == .preparing }
    }

    /// Overall progress (0.0 to 1.0) across all jobs
    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let finishedJobs = jobs.filter { $0.status.isFinished }.count
        let activeProgress = activeJob?.progress ?? 0
        return (Double(finishedJobs) + activeProgress) / Double(jobs.count)
    }

    /// Summary text for the queue status
    var statusSummary: String {
        if jobs.isEmpty {
            return "Queue empty"
        }
        if isProcessing, let active = activeJob {
            return "Processing: \(active.displayName)"
        }
        let pending = pendingCount
        if pending > 0 {
            return "\(pending) job\(pending == 1 ? "" : "s") waiting"
        }
        return "\(completedCount) completed, \(failedCount) failed"
    }

    /// Whether there are pending jobs that can be started
    var hasPendingJobs: Bool {
        pendingCount > 0
    }

    // MARK: - Init

    private init() {
        loadQueue()
    }

    // MARK: - Logging

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        consoleLog += "[\(timestamp)] \(message)\n"
    }

    func clearConsole() {
        consoleLog = ""
    }

    // MARK: - Persistence

    /// Saves the current queue to disk (async to avoid blocking main thread)
    private func saveQueue() {
        // Capture current state for background task
        let jobsToSave = self.jobs
        let fileURL = self.queueFileURL

        Task.detached(priority: .background) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601

                let data = try encoder.encode(jobsToSave)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Failed to save queue: \(error)")
            }
        }
    }

    /// Loads the queue from disk (only pending jobs)
    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: queueFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var loadedJobs = try decoder.decode([ConversionJob].self, from: data)

            // Only restore pending and failed jobs (not active/completed)
            loadedJobs = loadedJobs.filter { job in
                job.status == .pending || {
                    if case .failed = job.status { return true }
                    return false
                }()
            }

            // Reset any "active" or "preparing" states to pending, and resolve bookmarks
            for index in loadedJobs.indices {
                if loadedJobs[index].status == .active || loadedJobs[index].status == .preparing {
                    loadedJobs[index].status = .pending
                    loadedJobs[index].progress = 0
                }

                // Try to resolve security-scoped bookmarks
                if loadedJobs[index].cardBookmarkData != nil {
                    if loadedJobs[index].resolveCardBookmark() == nil {
                        // Bookmark resolution failed - mark job as failed
                        loadedJobs[index].status = .failed("Cannot access source folder (permission lost)")
                        log("Job '\(loadedJobs[index].displayName)' failed: Cannot access source folder")
                    }
                }
                if loadedJobs[index].outputBookmarkData != nil {
                    if loadedJobs[index].resolveOutputBookmark() == nil {
                        // Output bookmark resolution failed - mark job as failed
                        loadedJobs[index].status = .failed("Cannot access output folder (permission lost)")
                        log("Job '\(loadedJobs[index].displayName)' failed: Cannot access output folder")
                    }
                }
            }

            jobs = loadedJobs

            if !jobs.isEmpty {
                let pendingCount = jobs.filter { $0.status == .pending }.count
                let failedCount = jobs.filter { if case .failed = $0.status { return true } else { return false } }.count
                if failedCount > 0 {
                    log("Restored \(pendingCount) job(s), \(failedCount) failed (permission issues)")
                } else {
                    log("Restored \(jobs.count) job(s) from previous session")
                }
            }
        } catch {
            print("Failed to load queue: \(error)")
        }
    }

    // MARK: - Sleep Prevention

    /// Prevents the system from sleeping while processing
    private func preventSleep() {
        guard !isSleepPrevented else { return }

        let reason = "P2toMXF is converting video files" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )

        if result == kIOReturnSuccess {
            isSleepPrevented = true
            log("Sleep prevention enabled")
        }
    }

    /// Allows the system to sleep again
    private func allowSleep() {
        guard isSleepPrevented else { return }

        IOPMAssertionRelease(sleepAssertionID)
        isSleepPrevented = false
        sleepAssertionID = 0
        log("Sleep prevention disabled")
    }

    // MARK: - Security-Scoped Resource Management

    /// Starts accessing a security-scoped resource if not already accessed
    /// - Returns: true if access was granted (or already active), false if denied
    private func startAccessingIfNeeded(_ url: URL) -> Bool {
        // Normalize the URL to avoid duplicates with different representations
        let standardizedURL = url.standardizedFileURL
        guard !accessedSecurityScopedResources.contains(standardizedURL) else {
            return true  // Already accessing
        }
        if standardizedURL.startAccessingSecurityScopedResource() {
            accessedSecurityScopedResources.insert(standardizedURL)
            return true
        }
        return false
    }

    /// Stops accessing a specific security-scoped resource
    private func stopAccessingIfNeeded(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if accessedSecurityScopedResources.contains(standardizedURL) {
            standardizedURL.stopAccessingSecurityScopedResource()
            accessedSecurityScopedResources.remove(standardizedURL)
        }
    }

    /// Stops accessing all currently accessed security-scoped resources
    private func stopAccessingAllResources() {
        for url in accessedSecurityScopedResources {
            url.stopAccessingSecurityScopedResource()
        }
        accessedSecurityScopedResources.removeAll()
    }

    // MARK: - Filename Conflict Resolution

    /// Resolves filename conflicts by appending a counter
    private func resolveFilenameConflict(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        // Check against pending jobs
        let pendingDestinations = jobs
            .filter { $0.status == .pending }
            .map { $0.destinationURL.path }

        var finalURL = url
        var counter = 1

        while pendingDestinations.contains(finalURL.path) || FileManager.default.fileExists(atPath: finalURL.path) {
            let newFilename = "\(filename) (\(counter)).\(ext)"
            finalURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    // MARK: - Queue Management

    /// Adds a job to the queue (does NOT auto-start)
    /// - Parameter job: The conversion job to add
    /// - Parameter autoStart: If true, immediately starts processing (for "Convert Now" button)
    func addJob(_ job: ConversionJob, autoStart: Bool = false) {
        // Check for filename conflicts and resolve
        var finalJob = job
        let resolvedURL = resolveFilenameConflict(for: job.destinationURL)

        if resolvedURL != job.destinationURL {
            // Create new job with resolved URL, preserving bookmark data
            finalJob = ConversionJob(
                cardName: job.cardName,
                cardPath: job.cardPath,
                clips: job.clips,
                settings: job.settings,
                destinationURL: resolvedURL,
                cardBookmarkData: job.cardBookmarkData,
                outputBookmarkData: job.outputBookmarkData
            )
            log("Renamed output to avoid conflict: \(resolvedURL.lastPathComponent)")
        }

        jobs.append(finalJob)
        log("Added job: \(finalJob.displayName)")
        saveQueue()

        // Only auto-start if explicitly requested (for "Convert Now" button)
        if autoStart && !isProcessing {
            Task {
                await processQueue()
            }
        }
    }

    /// Creates and adds a job from parameters with security-scoped bookmarks
    func addJob(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL,
        autoStart: Bool = false
    ) {
        // Use withBookmarks to create security-scoped bookmarks for queue persistence
        let job = ConversionJob.withBookmarks(
            cardName: cardName,
            cardPath: cardPath,
            clips: clips,
            settings: settings,
            destinationURL: destinationURL
        )
        addJob(job, autoStart: autoStart)
    }

    /// Removes a job from the queue (only if pending, failed, or cancelled)
    func removeJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status != .active && jobs[index].status != .preparing else {
            return
        }
        let removed = jobs.remove(at: index)
        log("Removed job: \(removed.displayName)")
        saveQueue()
    }

    /// Clears all completed and failed jobs
    func clearFinishedJobs() {
        jobs.removeAll { $0.status.isFinished }
        log("Cleared finished jobs")
        saveQueue()
    }

    /// Retries a failed or cancelled job by resetting its status to pending
    func retryJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }

        let status = jobs[index].status
        guard case .failed = status else {
            guard status == .cancelled else { return }
            // Allow retry for cancelled jobs too
            jobs[index].status = .pending
            jobs[index].progress = 0
            log("Retrying job: \(jobs[index].displayName)")
            saveQueue()
            return
        }

        jobs[index].status = .pending
        jobs[index].progress = 0
        log("Retrying job: \(jobs[index].displayName)")
        saveQueue()
    }

    /// Cancels the currently active job
    func cancelCurrentJob() {
        guard let jobId = currentJobId,
              let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            return
        }

        ffmpeg.cancelConversion()
        jobs[index].status = .cancelled
        jobs[index].progress = 0
        log("Cancelled job: \(jobs[index].displayName)")
        saveQueue()
    }

    /// Cancels all pending jobs (marks as cancelled, doesn't remove)
    func cancelAllPending() {
        for index in jobs.indices where jobs[index].status == .pending {
            jobs[index].status = .cancelled
        }
        log("Cancelled all pending jobs")
        saveQueue()
    }

    /// Starts processing the queue (manual trigger)
    func startQueue() {
        guard !isProcessing, hasPendingJobs else { return }
        Task {
            await processQueue()
        }
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

    /// Checks current conversion speed and sets warning if significantly slow
    /// - Parameters:
    ///   - metrics: Current progress metrics from FFmpeg
    ///   - totalBytes: Total bytes being processed
    ///   - totalDuration: Total content duration in seconds
    ///   - outputPath: Output file path (for slow speed reason detection)
    private func checkForSlowSpeed(
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

    // MARK: - Queue Processing

    /// Main loop that processes jobs sequentially
    private func processQueue() async {
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
    private func processJob(_ job: ConversionJob) async {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }

        currentJobId = job.id
        jobs[index].status = .preparing
        jobs[index].progress = 0
        jobs[index].startedAt = Date()

        // Calculate and store estimate
        currentJobEstimate = speedTracker.estimateJob(job)

        log("--- Starting job: \(job.displayName) ---")
        log("Card: \(job.cardName)")
        log("Clips: \(job.clips.count)")
        log("Output: \(job.destinationURL.path)")
        if let estimate = currentJobEstimate {
            log("Estimated time: \(estimate.formattedEstimate) (\(estimate.formattedSpeed))")
        }

        // Resolve bookmarks and start security-scoped access
        var mutableJob = job
        let cardURL: URL
        if let resolvedCardURL = mutableJob.resolveCardBookmark() {
            cardURL = resolvedCardURL
            // Update the job in the array with refreshed bookmark if it was stale
            jobs[index] = mutableJob
        } else {
            cardURL = job.cardPath
        }

        let outputDirURL: URL
        if let resolvedOutputURL = mutableJob.resolveOutputBookmark() {
            outputDirURL = resolvedOutputURL
            jobs[index] = mutableJob
        } else {
            outputDirURL = job.destinationURL.deletingLastPathComponent()
        }

        // Start security-scoped access using balanced tracking to prevent nested start/stop issues
        let cardAccessGranted = startAccessingIfNeeded(cardURL)
        let outputAccessGranted = startAccessingIfNeeded(outputDirURL)
        defer {
            if cardAccessGranted {
                stopAccessingIfNeeded(cardURL)
            }
            if outputAccessGranted {
                stopAccessingIfNeeded(outputDirURL)
            }
        }

        let startTime = Date()
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let contentDuration = Double(job.totalDurationFrames) / fps

        do {
            jobs[index].status = .active

            switch job.settings.processingMode {
            case .concatenate:
                try await processConcatenateJob(job, index: index)
            case .individual:
                try await processIndividualJob(job, index: index)
            }

            jobs[index].status = .completed
            jobs[index].progress = 1.0

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
            if jobs[index].status == .cancelled {
                log("Job cancelled: \(job.displayName)")
            } else {
                jobs[index].status = .failed(error.localizedDescription)
                log("FAILED: \(job.displayName) - \(error.localizedDescription)")
            }
        }

        // Clear job-specific state
        currentJobId = nil
        currentJobEstimate = nil
        slowSpeedWarning = nil
    }

    /// Processes a concatenation job (multiple clips -> single file)
    private func processConcatenateJob(_ job: ConversionJob, index: Int) async throws {
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let totalDuration = Double(job.totalDurationFrames) / fps

        try await ffmpeg.mergeClips(
            job.clips,
            to: job.destinationURL,
            settings: job.settings
        ) { [weak self] progress, message in
            Task { @MainActor in
                self?.jobs[index].progress = progress
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
    }

    /// Processes an individual files job (each clip -> separate file)
    private func processIndividualJob(_ job: ConversionJob, index: Int) async throws {
        let outputDir = job.destinationURL
        let ext = job.settings.outputContainer.fileExtension

        // Calculate totals for slow speed detection
        let totalBytes = job.clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let fps = job.clips.first?.frameRateDouble ?? 25.0
        let totalDuration = Double(job.totalDurationFrames) / fps

        for (clipIndex, clip) in job.clips.enumerated() {
            // Check if job was cancelled
            guard jobs[index].status == .active else {
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
                    self?.jobs[index].progress = baseProgress + clipContribution
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

            log("Created: \(clipOutputURL.lastPathComponent)")
        }
    }

    // MARK: - Verification

    /// Number of jobs pending verification
    var unverifiedCompletedCount: Int {
        jobs.filter { $0.status == .completed && $0.verificationStatus == .unverified }.count
    }

    /// Verifies a completed job
    /// - Parameters:
    ///   - jobId: The job to verify
    ///   - mode: Quick or Full verification
    func verifyJob(_ jobId: UUID, mode: VerificationMode) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .completed else {
            return
        }

        Task {
            await performVerification(index: index, mode: mode)
        }
    }

    /// Verifies all completed but unverified jobs
    func verifyAllCompleted(mode: VerificationMode) {
        let unverifiedJobs = jobs.enumerated().filter {
            $0.element.status == .completed && $0.element.verificationStatus == .unverified
        }

        guard !unverifiedJobs.isEmpty else { return }

        Task {
            for (index, _) in unverifiedJobs {
                // Check if verification was cancelled
                guard !verificationService.isCancelling else { break }
                await performVerification(index: index, mode: mode)
            }
        }
    }

    /// Performs verification on a job at the given index
    private func performVerification(index: Int, mode: VerificationMode) async {
        guard index < jobs.count else { return }

        let job = jobs[index]
        currentVerificationJobId = job.id
        isVerifying = true
        jobs[index].verificationStatus = .verifying
        jobs[index].verificationProgress = 0

        log("--- Verifying: \(job.displayName) (\(mode.rawValue)) ---")

        do {
            // For individual mode, verify each output file
            if job.settings.processingMode == .individual {
                try await verifyIndividualJobOutputs(job: job, index: index, mode: mode)
            } else {
                // For concatenate mode, verify single output file
                let result = try await verificationService.verify(
                    fileURL: job.destinationURL,
                    mode: mode,
                    expectedFrames: job.totalDurationFrames,
                    progress: { [weak self] progress, message in
                        Task { @MainActor in
                            self?.jobs[index].verificationProgress = progress
                        }
                    },
                    logHandler: { [weak self] message in
                        Task { @MainActor in
                            self?.log(message)
                        }
                    }
                )

                jobs[index].verificationResult = result
                jobs[index].verificationStatus = result.passed ? .verified : .failed(result.errorMessage ?? "Unknown error")
            }

        } catch VerificationService.VerificationError.cancelled {
            jobs[index].verificationStatus = .unverified
            jobs[index].verificationProgress = 0
            log("Verification cancelled")
        } catch {
            jobs[index].verificationStatus = .failed(error.localizedDescription)
            log("Verification failed: \(error.localizedDescription)")
        }

        currentVerificationJobId = nil
        isVerifying = jobs.contains { $0.verificationStatus == .verifying }
        saveQueue()
    }

    /// Verifies individual output files from an individual-mode job
    private func verifyIndividualJobOutputs(job: ConversionJob, index: Int, mode: VerificationMode) async throws {
        let outputDir = job.destinationURL
        let ext = job.settings.outputContainer.fileExtension

        var allPassed = true
        var failedClips: [String] = []

        for (clipIndex, clip) in job.clips.enumerated() {
            let clipOutputURL = outputDir.appendingPathComponent("\(clip.displayName).\(ext)")

            log("Verifying [\(clipIndex + 1)/\(job.clips.count)]: \(clip.displayName)")

            let result = try await verificationService.verify(
                fileURL: clipOutputURL,
                mode: mode,
                expectedFrames: clip.durationFrames,
                progress: { [weak self] progress, message in
                    Task { @MainActor in
                        let baseProgress = Double(clipIndex) / Double(job.clips.count)
                        let clipContribution = progress / Double(job.clips.count)
                        self?.jobs[index].verificationProgress = baseProgress + clipContribution
                    }
                },
                logHandler: { [weak self] message in
                    Task { @MainActor in
                        self?.log(message)
                    }
                }
            )

            if !result.passed {
                allPassed = false
                failedClips.append(clip.displayName)
            }
        }

        if allPassed {
            jobs[index].verificationStatus = .verified
            jobs[index].verificationResult = VerificationResult(
                fileURL: outputDir,
                passed: true,
                mode: mode,
                duration: 0,
                framesDecoded: job.totalDurationFrames,
                totalFrames: job.totalDurationFrames,
                decodingSpeed: nil,
                containerValid: true,
                errorMessage: nil,
                verifiedAt: Date()
            )
        } else {
            let errorMsg = "Failed clips: \(failedClips.joined(separator: ", "))"
            jobs[index].verificationStatus = .failed(errorMsg)
        }
    }

    /// Cancels the current verification
    func cancelVerification() {
        verificationService.cancel()
        if let jobId = currentVerificationJobId,
           let index = jobs.firstIndex(where: { $0.id == jobId }) {
            jobs[index].verificationStatus = .unverified
            jobs[index].verificationProgress = 0
        }
        isVerifying = false
    }
}
