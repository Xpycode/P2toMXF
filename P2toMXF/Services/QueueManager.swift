import Foundation
import SwiftUI
import IOKit
import IOKit.pwr_mgt

/// Manages a queue of conversion jobs, executing them sequentially
@MainActor
class QueueManager: ObservableObject {
    // MARK: - Shared Instance
    static let shared = QueueManager()

    // MARK: - Published State
    @Published private(set) var jobs: [ConversionJob] = []
    @Published private(set) var isProcessing = false
    @Published var consoleLog: String = ""

    // MARK: - Private
    private let ffmpeg = FFmpegWrapper()
    private let verificationService = VerificationService()
    private var currentJobId: UUID?
    private var currentVerificationJobId: UUID?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isSleepPrevented = false
    @Published private(set) var isVerifying = false

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

    /// Saves the current queue to disk
    private func saveQueue() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(jobs)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            print("Failed to save queue: \(error)")
        }
    }

    /// Loads the queue from disk (only pending jobs)
    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: queueFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let loadedJobs = try decoder.decode([ConversionJob].self, from: data)

            // Only restore pending and failed jobs (not active/completed)
            jobs = loadedJobs.filter { job in
                job.status == .pending || {
                    if case .failed = job.status { return true }
                    return false
                }()
            }

            // Reset any "active" or "preparing" states to pending
            for index in jobs.indices {
                if jobs[index].status == .active || jobs[index].status == .preparing {
                    jobs[index].status = .pending
                    jobs[index].progress = 0
                }
            }

            if !jobs.isEmpty {
                log("Restored \(jobs.count) job(s) from previous session")
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
            // Create new job with resolved URL
            finalJob = ConversionJob(
                cardName: job.cardName,
                cardPath: job.cardPath,
                clips: job.clips,
                settings: job.settings,
                destinationURL: resolvedURL
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

    /// Creates and adds a job from parameters
    func addJob(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL,
        autoStart: Bool = false
    ) {
        let job = ConversionJob(
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

        log("--- Starting job: \(job.displayName) ---")
        log("Card: \(job.cardName)")
        log("Clips: \(job.clips.count)")
        log("Output: \(job.destinationURL.path)")

        // Start security-scoped access to the card
        let accessGranted = job.cardPath.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                job.cardPath.stopAccessingSecurityScopedResource()
            }
        }

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
            log("SUCCESS: \(job.displayName)")

        } catch {
            // Check if cancelled vs actual error
            if jobs[index].status == .cancelled {
                log("Job cancelled: \(job.displayName)")
            } else {
                jobs[index].status = .failed(error.localizedDescription)
                log("FAILED: \(job.displayName) - \(error.localizedDescription)")
            }
        }

        currentJobId = nil
    }

    /// Processes a concatenation job (multiple clips -> single file)
    private func processConcatenateJob(_ job: ConversionJob, index: Int) async throws {
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
        }
    }

    /// Processes an individual files job (each clip -> separate file)
    private func processIndividualJob(_ job: ConversionJob, index: Int) async throws {
        let outputDir = job.destinationURL
        let ext = job.settings.outputContainer.fileExtension

        for (clipIndex, clip) in job.clips.enumerated() {
            // Check if job was cancelled
            guard jobs[index].status == .active else {
                throw NSError(domain: "QueueManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Job cancelled"])
            }

            let clipOutputURL = outputDir.appendingPathComponent("\(clip.displayName).\(ext)")
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
