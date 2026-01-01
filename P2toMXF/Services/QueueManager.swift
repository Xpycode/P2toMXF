import Foundation
import SwiftUI

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
    private var currentJobId: UUID?

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

    // MARK: - Init

    private init() {}

    // MARK: - Logging

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        consoleLog += "[\(timestamp)] \(message)\n"
    }

    func clearConsole() {
        consoleLog = ""
    }

    // MARK: - Queue Management

    /// Adds a job to the queue
    /// - Parameter job: The conversion job to add
    func addJob(_ job: ConversionJob) {
        jobs.append(job)
        log("Added job: \(job.displayName)")

        // Auto-start if not already processing
        if !isProcessing {
            Task {
                await processQueue()
            }
        }
    }

    /// Creates and adds a job from the current ViewModel state
    /// - Parameters:
    ///   - cardName: Name of the P2 card
    ///   - cardPath: Path to the P2 card (for security-scoped access)
    ///   - clips: Clips to process
    ///   - settings: Conversion settings
    ///   - destinationURL: Output path
    func addJob(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL
    ) {
        let job = ConversionJob(
            cardName: cardName,
            cardPath: cardPath,
            clips: clips,
            settings: settings,
            destinationURL: destinationURL
        )
        addJob(job)
    }

    /// Removes a job from the queue (only if pending, failed, or cancelled)
    func removeJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status != .active && jobs[index].status != .preparing else {
            return
        }
        let removed = jobs.remove(at: index)
        log("Removed job: \(removed.displayName)")
    }

    /// Clears all completed and failed jobs
    func clearFinishedJobs() {
        jobs.removeAll { $0.status.isFinished }
        log("Cleared finished jobs")
    }

    /// Retries a failed job by resetting its status to pending
    func retryJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              case .failed = jobs[index].status else {
            return
        }

        jobs[index].status = .pending
        jobs[index].progress = 0
        log("Retrying job: \(jobs[index].displayName)")

        // Auto-start if not already processing
        if !isProcessing {
            Task {
                await processQueue()
            }
        }
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
    }

    /// Cancels all pending jobs (marks as cancelled, doesn't remove)
    func cancelAllPending() {
        for index in jobs.indices where jobs[index].status == .pending {
            jobs[index].status = .cancelled
        }
        log("Cancelled all pending jobs")
    }

    /// Starts processing the queue if not already running
    func startQueue() {
        guard !isProcessing else { return }
        Task {
            await processQueue()
        }
    }

    // MARK: - Queue Processing

    /// Main loop that processes jobs sequentially
    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true

        log("=== Queue processing started ===")

        while let nextJob = jobs.first(where: { $0.status == .pending }) {
            await processJob(nextJob)
        }

        isProcessing = false
        log("=== Queue processing complete ===")
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
}
