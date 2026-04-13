import Foundation

extension QueueManager {

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
        guard let idx = jobIndex(for: jobId),
              jobs[idx].status == .completed else {
            return
        }

        Task {
            await performVerification(jobId: jobId, mode: mode)
        }
    }

    /// Verifies all completed but unverified jobs
    func verifyAllCompleted(mode: VerificationMode) {
        let unverifiedJobIds = jobs.filter {
            $0.status == .completed && $0.verificationStatus == .unverified
        }.map(\.id)

        guard !unverifiedJobIds.isEmpty else { return }

        verificationTask = Task {
            for jobId in unverifiedJobIds {
                // Use structured cancellation instead of manual isCancelling flag
                try Task.checkCancellation()
                await performVerification(jobId: jobId, mode: mode)
            }
        }
    }

    /// Performs verification on a job by ID
    func performVerification(jobId: UUID, mode: VerificationMode) async {
        guard let idx = jobIndex(for: jobId) else { return }

        let job = jobs[idx]
        currentVerificationJobId = job.id
        isVerifying = true
        updateJob(jobId) { j in
            j.verificationStatus = .verifying
            j.verificationProgress = 0
        }

        log("--- Verifying: \(job.displayName) (\(mode.rawValue)) ---")

        do {
            // For individual mode, verify each output file
            if job.settings.processingMode == .individual {
                try await verifyIndividualJobOutputs(job: job, jobId: jobId, mode: mode)
            } else {
                // For concatenate mode, verify single output file
                // Handle legacy jobs where destinationURL might be a directory
                var fileURL = job.destinationURL
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    // destinationURL is a directory - search for matching output file
                    let ext = job.settings.outputContainer.fileExtension
                    // Determine base name to search for
                    let baseName: String
                    if !job.settings.outputFilename.isEmpty {
                        baseName = job.settings.outputFilename
                    } else if job.settings.useFolderNameAsFilename {
                        baseName = job.cardName
                    } else {
                        baseName = job.cardName
                    }

                    // Search for files matching the base name pattern
                    let foundFile = findMatchingOutputFile(
                        inDirectory: job.destinationURL,
                        baseName: baseName,
                        extension: ext
                    )

                    if let found = foundFile {
                        fileURL = found
                        log("Found output file: \(fileURL.lastPathComponent)")
                    } else {
                        // Fallback to constructed path (will likely fail but shows clear error)
                        fileURL = job.destinationURL.appendingPathComponent("\(baseName).\(ext)")
                        log("Warning: No matching file found, trying: \(fileURL.lastPathComponent)")
                    }
                }

                let result = try await verificationService.verify(
                    fileURL: fileURL,
                    mode: mode,
                    expectedFrames: job.totalDurationFrames,
                    progress: { [weak self] progress, message in
                        Task { @MainActor in
                            self?.updateJob(jobId) { $0.verificationProgress = progress }
                        }
                    },
                    logHandler: { [weak self] message in
                        Task { @MainActor in
                            self?.log(message)
                        }
                    }
                )

                updateJob(jobId) { j in
                    j.verificationResult = result
                    j.verificationStatus = result.passed ? .verified : .failed(result.errorMessage ?? "Unknown error")
                }
            }

        } catch VerificationService.VerificationError.cancelled {
            updateJob(jobId) { j in
                j.verificationStatus = .unverified
                j.verificationProgress = 0
            }
            log("Verification cancelled")
        } catch {
            updateJob(jobId) { $0.verificationStatus = .failed(error.localizedDescription) }
            log("Verification failed: \(error.localizedDescription)")
        }

        currentVerificationJobId = nil
        isVerifying = jobs.contains { $0.verificationStatus == .verifying }
        saveQueue()
    }

    /// Verifies individual output files from an individual-mode job
    func verifyIndividualJobOutputs(job: ConversionJob, jobId: UUID, mode: VerificationMode) async throws {
        var allPassed = true
        var failedClips: [String] = []

        // Use actualOutputURLs if available (recorded during conversion)
        // This handles filename conflict resolution correctly
        let outputURLs: [URL]
        if !job.actualOutputURLs.isEmpty {
            outputURLs = job.actualOutputURLs
        } else {
            // Fallback for legacy jobs: reconstruct from clip names
            let outputDir = job.destinationURL
            let ext = job.settings.outputContainer.fileExtension
            outputURLs = job.clips.map { outputDir.appendingPathComponent("\($0.displayName).\(ext)") }
        }

        for (clipIndex, clipOutputURL) in outputURLs.enumerated() {
            let clipName = clipOutputURL.deletingPathExtension().lastPathComponent
            log("Verifying [\(clipIndex + 1)/\(outputURLs.count)]: \(clipName)")

            // Get expected frames from corresponding clip if indices align
            let expectedFrames: Int? = clipIndex < job.clips.count ? job.clips[clipIndex].durationFrames : nil

            let result = try await verificationService.verify(
                fileURL: clipOutputURL,
                mode: mode,
                expectedFrames: expectedFrames ?? 0,
                progress: { [weak self] progress, message in
                    Task { @MainActor in
                        let baseProgress = Double(clipIndex) / Double(outputURLs.count)
                        let clipContribution = progress / Double(outputURLs.count)
                        self?.updateJob(jobId) { $0.verificationProgress = baseProgress + clipContribution }
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
                failedClips.append(clipName)
            }
        }

        if allPassed {
            updateJob(jobId) { j in
                j.verificationStatus = .verified
                j.verificationResult = VerificationResult(
                    fileURL: job.destinationURL,
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
            }
        } else {
            let errorMsg = "Failed clips: \(failedClips.joined(separator: ", "))"
            updateJob(jobId) { $0.verificationStatus = .failed(errorMsg) }
        }
    }

    /// Cancels the current verification
    func cancelVerification() {
        // Cancel the batch verification task (structured cancellation)
        verificationTask?.cancel()
        verificationTask = nil
        // Also cancel the active subprocess
        verificationService.cancel()
        if let jobId = currentVerificationJobId {
            updateJob(jobId) { j in
                j.verificationStatus = .unverified
                j.verificationProgress = 0
            }
        }
        isVerifying = false
    }

    // MARK: - File Search Helpers

    /// Finds a matching output file in a directory based on base name pattern
    /// Searches for files that start with the base name and have the correct extension
    /// Handles group suffixes like " - Group 1" or "_03" that may have been added
    func findMatchingOutputFile(
        inDirectory directory: URL,
        baseName: String,
        extension ext: String
    ) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }

        // Filter for files with matching extension
        let matchingFiles = contents.filter { filename in
            filename.lowercased().hasSuffix(".\(ext)")
        }

        // First, look for exact match
        let exactName = "\(baseName).\(ext)"
        if matchingFiles.contains(exactName) {
            return directory.appendingPathComponent(exactName)
        }

        // Look for files that start with the base name (handles group suffixes)
        // Sort by name to get consistent results
        let candidates = matchingFiles.filter { filename in
            filename.hasPrefix(baseName)
        }.sorted()

        // Return the first match if any
        if let firstMatch = candidates.first {
            return directory.appendingPathComponent(firstMatch)
        }

        // Also try matching with cardName variations (spaces, underscores)
        let normalizedBaseName = baseName.replacingOccurrences(of: " ", with: "")
        let fallbackCandidates = matchingFiles.filter { filename in
            filename.replacingOccurrences(of: " ", with: "").hasPrefix(normalizedBaseName)
        }.sorted()

        if let fallbackMatch = fallbackCandidates.first {
            return directory.appendingPathComponent(fallbackMatch)
        }

        return nil
    }
}
