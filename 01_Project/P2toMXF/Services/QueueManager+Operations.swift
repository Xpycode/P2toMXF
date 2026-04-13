import Foundation

extension QueueManager {

    // MARK: - Queue Management

    /// Adds a job to the queue (does NOT auto-start)
    /// - Parameter job: The conversion job to add
    /// - Parameter autoStart: If true, immediately starts processing (for "Convert Now" button)
    func addJob(_ job: ConversionJob, autoStart: Bool = false) {
        var finalJob = job

        // Only resolve filename conflicts for FILES, not directories
        // Individual mode uses directory as destination (each clip creates its own file)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: job.destinationURL.path, isDirectory: &isDirectory)

        // Skip conflict resolution if: doesn't exist yet, or exists but is a directory (individual mode)
        let shouldResolveConflict = exists && !isDirectory.boolValue

        if shouldResolveConflict {
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

    /// Stops all queue processing - cancels current job and all pending jobs
    func stopAllProcessing() {
        // Cancel current job if running
        if let jobId = currentJobId,
           let index = jobs.firstIndex(where: { $0.id == jobId }) {
            ffmpeg.cancelConversion()
            jobs[index].status = .cancelled
            jobs[index].progress = 0
            log("Cancelled active job: \(jobs[index].displayName)")
        }

        // Cancel all pending jobs
        var pendingCount = 0
        for index in jobs.indices where jobs[index].status == .pending {
            jobs[index].status = .cancelled
            pendingCount += 1
        }
        if pendingCount > 0 {
            log("Cancelled \(pendingCount) pending job\(pendingCount == 1 ? "" : "s")")
        }

        saveQueue()
        log("=== All queue processing stopped ===")
    }

    /// Starts processing the queue (manual trigger)
    func startQueue() {
        guard !isProcessing, hasPendingJobs else { return }
        Task {
            await processQueue()
        }
    }
}
