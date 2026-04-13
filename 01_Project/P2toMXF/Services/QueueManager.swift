import Foundation
import SwiftUI
import IOKit
import IOKit.pwr_mgt

/// Manages a queue of conversion jobs, executing them sequentially
@MainActor
class QueueManager: ObservableObject {
    // MARK: - Static Formatters
    /// Cached DateFormatter for log timestamps (creating formatters is expensive)
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - Shared Instance
    @MainActor static let shared = QueueManager()

    // MARK: - Published State
    @Published var jobs: [ConversionJob] = []
    @Published var isProcessing = false

    /// Console log lines - stored as array to enable efficient trimming
    /// Use `consoleLog` for display (joins lines)
    private var consoleLines: [String] = []

    /// Maximum number of console lines to retain (prevents unbounded memory growth)
    private let maxConsoleLines = 5000

    /// Console log as single string for display
    var consoleLog: String {
        consoleLines.joined(separator: "\n")
    }

    // MARK: - Private
    let ffmpeg = FFmpegWrapper()
    let verificationService = VerificationService()
    let speedTracker = SpeedTracker.shared
    var currentJobId: UUID?
    var currentVerificationJobId: UUID?
    var sleepAssertionID: IOPMAssertionID = 0
    var isSleepPrevented = false
    /// Tracks URLs that currently have active security-scoped access
    var accessedSecurityScopedResources: Set<URL> = []
    /// Task handle for batch verification (supports structured cancellation)
    var verificationTask: Task<Void, Error>?
    @Published var isVerifying = false
    @Published var slowSpeedWarning: SlowSpeedWarning?
    @Published var currentJobEstimate: ConversionEstimate?
    /// Error message when queue persistence fails (nil if no error)
    /// Displayed in UI to warn users their queue may not survive app restarts
    @Published var persistenceError: String?

    // MARK: - Persistence
    private static let queueFileName = "queue.json"

    /// URL for the queue persistence file (nil if persistence unavailable)
    /// Gracefully degrades to in-memory queue if Application Support is inaccessible
    var queueFileURL: URL?

    /// Sets up the persistence file URL if possible
    private func setupPersistence() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log("Warning: Application Support unavailable - queue will not persist")
            return
        }

        let appFolder = appSupport.appendingPathComponent("P2toMXF", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
            queueFileURL = appFolder.appendingPathComponent(Self.queueFileName)
        } catch {
            log("Warning: Cannot create app folder - queue will not persist: \(error.localizedDescription)")
        }
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
        setupPersistence()
        loadQueue()
    }

    // MARK: - Logging

    func log(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        consoleLines.append(line)

        // Trim old lines if over limit (keep last maxConsoleLines)
        if consoleLines.count > maxConsoleLines {
            let excess = consoleLines.count - maxConsoleLines
            consoleLines.removeFirst(excess)
        }

        // Trigger UI update
        objectWillChange.send()
    }

    func clearConsole() {
        consoleLines.removeAll()
        objectWillChange.send()
    }

    // MARK: - Persistence

    /// Saves the current queue to disk (async to avoid blocking main thread)
    /// No-op if persistence is unavailable
    func saveQueue() {
        // Skip if persistence unavailable
        guard let fileURL = self.queueFileURL else { return }

        // Capture current state for background task
        let jobsToSave = self.jobs

        Task.detached(priority: .background) { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601

                let data = try encoder.encode(jobsToSave)
                try data.write(to: fileURL, options: .atomic)

                // Clear any previous error on success
                await MainActor.run { [weak self] in
                    self?.persistenceError = nil
                }
            } catch {
                // Surface the error to UI (only first occurrence to avoid spam)
                let errorMessage = error.localizedDescription
                await MainActor.run { [weak self] in
                    if self?.persistenceError == nil {
                        self?.persistenceError = "Queue may not persist: \(errorMessage)"
                        self?.log("Warning: Failed to save queue - \(errorMessage)")
                    }
                }
            }
        }
    }

    /// Loads the queue from disk (only pending jobs)
    /// No-op if persistence is unavailable
    private func loadQueue() {
        guard let fileURL = queueFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
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
            #if DEBUG
            print("Failed to load queue: \(error)")
            #endif
        }
    }

    // MARK: - Sleep Prevention

    /// Prevents the system from sleeping while processing
    func preventSleep() {
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
    func allowSleep() {
        guard isSleepPrevented else { return }

        IOPMAssertionRelease(sleepAssertionID)
        isSleepPrevented = false
        sleepAssertionID = 0
        log("Sleep prevention disabled")
    }

    // MARK: - Security-Scoped Resource Management

    /// Result of attempting to start security-scoped access
    enum AccessResult {
        case newlyGranted    // We started access - caller SHOULD stop it
        case alreadyActive   // Someone else started it - caller should NOT stop
        case denied          // Access failed

        var wasGranted: Bool {
            self != .denied
        }
    }

    /// Starts accessing a security-scoped resource if not already accessed
    /// - Returns: AccessResult indicating whether caller should stop access later
    func startAccessingIfNeeded(_ url: URL) -> AccessResult {
        // Normalize the URL to avoid duplicates with different representations
        let standardizedURL = url.standardizedFileURL

        // Check if already accessing (someone else started it)
        if accessedSecurityScopedResources.contains(standardizedURL) {
            return .alreadyActive
        }

        // Try to start new access
        if standardizedURL.startAccessingSecurityScopedResource() {
            accessedSecurityScopedResources.insert(standardizedURL)
            return .newlyGranted
        }

        return .denied
    }

    /// Stops accessing a specific security-scoped resource
    func stopAccessingIfNeeded(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if accessedSecurityScopedResources.contains(standardizedURL) {
            standardizedURL.stopAccessingSecurityScopedResource()
            accessedSecurityScopedResources.remove(standardizedURL)
        }
    }

    /// Stops accessing all currently accessed security-scoped resources
    func stopAccessingAllResources() {
        for url in accessedSecurityScopedResources {
            url.stopAccessingSecurityScopedResource()
        }
        accessedSecurityScopedResources.removeAll()
    }

    // MARK: - Filename Conflict Resolution

    /// Checks if a filename conflicts with any existing or queued outputs
    private func isFilenameConflicting(_ url: URL) -> Bool {
        let path = url.path

        // Check all job destinations (any state)
        for job in jobs {
            if job.destinationURL.path == path {
                return true
            }
            // Also check actual output files (may have been renamed during conversion)
            if job.actualOutputURLs.contains(where: { $0.path == path }) {
                return true
            }
        }

        // Check filesystem
        return FileManager.default.fileExists(atPath: path)
    }

    /// Resolves filename conflicts by appending a counter
    func resolveFilenameConflict(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var finalURL = url
        var counter = 1

        while isFilenameConflicting(finalURL) {
            let newFilename = "\(filename) (\(counter)).\(ext)"
            finalURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    // MARK: - Safe Job Lookup

    /// Safely updates a job property by looking up the current index by ID.
    /// Returns false if the job is no longer in the array.
    @discardableResult
    func updateJob(_ jobId: UUID, _ update: (inout ConversionJob) -> Void) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return false }
        update(&jobs[index])
        return true
    }

    /// Returns the current index for a job ID, or nil if removed.
    func jobIndex(for jobId: UUID) -> Int? {
        jobs.firstIndex(where: { $0.id == jobId })
    }
}
