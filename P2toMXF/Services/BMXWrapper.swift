import Foundation

/// Wrapper for BMX (BBC MXF) tools for professional MXF handling
/// BMX properly handles P2 OPAtom MXF files where FFmpeg fails
class BMXWrapper {

    enum BMXError: LocalizedError {
        case bmxNotFound
        case conversionFailed(String)
        case invalidInput(String)
        case cancelled  // User-initiated cancellation

        var errorDescription: String? {
            switch self {
            case .bmxNotFound:
                return "BMX tools not found in app bundle. Please add bmxtranswrap to Resources."
            case .conversionFailed(let msg):
                return "BMX conversion failed: \(msg)"
            case .invalidInput(let msg):
                return "Invalid input: \(msg)"
            case .cancelled:
                return "BMX operation was cancelled"
            }
        }
    }

    /// Progress callback: (progress 0.0-1.0, current status message)
    typealias ProgressHandler = (Double, String) -> Void
    /// Log callback for console output
    typealias LogHandler = (String) -> Void

    private var currentProcess: Process?
    private var isCancelling = false  // Flag to distinguish cancellation from failure
    private let toolResolver = BundledToolResolver.shared

    /// Path to the bundled bmxtranswrap binary
    var bmxTranswrapPath: URL? {
        toolResolver.path(for: .bmxtranswrap)
    }

    /// Path to the bundled mxf2raw binary
    var mxf2rawPath: URL? {
        toolResolver.path(for: .mxf2raw)
    }

    /// Path to the lib directory containing BMX dylibs
    var libPath: URL? {
        toolResolver.bmxLibPath
    }

    /// Checks if BMX tools are available
    var isBMXAvailable: Bool {
        toolResolver.isAvailable(BundledTool.bmxtranswrap) && toolResolver.bmxLibPath != nil
    }

    /// Rewraps a P2 clip (OPAtom) to a single OP1a MXF file
    /// This is the key operation that FFmpeg cannot do - BMX handles P2's index tables correctly
    /// - Parameters:
    ///   - clip: The P2 clip to convert
    ///   - outputURL: Destination path for the output MXF
    ///   - progress: Progress callback
    ///   - logHandler: Log callback for console output
    func rewrapClip(
        _ clip: P2Clip,
        to outputURL: URL,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in }
    ) async throws {
        guard let bmx = bmxTranswrapPath else {
            logHandler("ERROR: bmxtranswrap not found!")
            throw BMXError.bmxNotFound
        }

        guard !clip.videoFiles.isEmpty else {
            logHandler("ERROR: No video files found for clip")
            throw BMXError.invalidInput("No video files found for clip")
        }

        progress(0.0, "Preparing BMX rewrap...")

        // Build bmxtranswrap arguments
        var args = [String]()

        // Output type: OP1a MXF (single file with all essence)
        args.append(contentsOf: ["-t", "op1a"])

        // Output file
        args.append(contentsOf: ["-o", outputURL.path])

        // Input files: video first, then all audio channels
        for videoFile in clip.videoFiles {
            args.append(videoFile.path)
        }
        for audioFile in clip.audioFiles {
            args.append(audioFile.path)
        }

        // Log the command
        let commandStr = "bmxtranswrap " + args.joined(separator: " ")
        logHandler("Command: \(commandStr)")

        progress(0.1, "Starting BMX rewrap...")

        // Execute BMX
        try await runBMX(at: bmx, arguments: args, progress: progress, logHandler: logHandler)

        progress(1.0, "Rewrap complete")
    }

    /// Rewraps multiple P2 clips to individual OP1a MXF files
    /// Returns paths to the rewrapped files (for subsequent concatenation with FFmpeg)
    func rewrapClips(
        _ clips: [P2Clip],
        toDirectory tempDir: URL,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in }
    ) async throws -> [URL] {
        var rewrappedFiles: [URL] = []

        for (index, clip) in clips.enumerated() {
            let clipProgress = Double(index) / Double(clips.count)
            progress(clipProgress, "Rewrapping clip \(index + 1) of \(clips.count)...")

            let outputFile = tempDir.appendingPathComponent("\(clip.clipName)_rewrapped.mxf")

            try await rewrapClip(
                clip,
                to: outputFile,
                progress: { p, msg in
                    // Scale progress for this clip within overall progress
                    let overallProgress = clipProgress + (p / Double(clips.count))
                    progress(overallProgress, msg)
                },
                logHandler: logHandler
            )

            rewrappedFiles.append(outputFile)
        }

        return rewrappedFiles
    }

    /// Thread-safe container for collecting process output.
    ///
    /// # Threading Contract
    /// This class is marked `@unchecked Sendable` because it manually implements
    /// thread-safety using `NSLock`:
    /// - `append(_:)` and `output` are synchronized via the internal lock
    /// - Safe to call from any thread or dispatch queue
    /// - All mutable state (`_output`) is protected by the lock
    ///
    /// **Warning:** Do not add properties without updating lock usage.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _output = ""

        func append(_ string: String) {
            lock.lock()
            _output += string
            lock.unlock()
        }

        var output: String {
            lock.lock()
            defer { lock.unlock() }
            return _output
        }
    }

    /// Runs a BMX tool with the given arguments
    private func runBMX(
        at bmxURL: URL,
        arguments: [String],
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = bmxURL
            process.arguments = arguments

            // Set library path for BMX dylibs using centralized resolver
            process.environment = toolResolver.bmxEnvironment()

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let outputCollector = OutputCollector()
            let errorCollector = OutputCollector()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    outputCollector.append(str)
                    DispatchQueue.main.async {
                        logHandler("BMX: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    errorCollector.append(str)
                    DispatchQueue.main.async {
                        logHandler("BMX: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            }

            process.terminationHandler = { [weak self] proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let wasCancelled = self?.isCancelling ?? false

                DispatchQueue.main.async {
                    logHandler("BMX exit code: \(proc.terminationStatus)\(wasCancelled ? " (cancelled)" : "")")
                }

                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else if wasCancelled {
                    // Process was terminated by user cancellation
                    continuation.resume(throwing: BMXError.cancelled)
                } else {
                    let errorOutput = errorCollector.output + outputCollector.output
                    DispatchQueue.main.async {
                        logHandler("BMX error output: \(errorOutput)")
                    }
                    continuation.resume(throwing: BMXError.conversionFailed(errorOutput))
                }
            }

            self.currentProcess = process

            DispatchQueue.main.async {
                logHandler("Starting BMX: \(bmxURL.path)")
            }

            do {
                try process.run()
                DispatchQueue.main.async {
                    logHandler("BMX started with PID: \(process.processIdentifier)")
                }
            } catch {
                // Clean up file handle handlers if process fails to start
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    logHandler("Failed to start BMX: \(error.localizedDescription)")
                }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Cancels any running operation
    /// Uses process group killing to ensure child processes are also terminated
    func cancel() {
        isCancelling = true

        if let process = currentProcess, process.isRunning {
            let pid = process.processIdentifier

            // Kill the entire process group to catch any child processes
            let pgid = getpgid(pid)
            if pgid > 0 {
                kill(-pgid, SIGTERM)  // Negative PID = kill process group
            }

            // Also terminate via Swift API as backup
            process.terminate()
        }

        currentProcess = nil
    }

    /// Resets cancellation state - call before starting new operation
    func resetCancellation() {
        isCancelling = false
    }

    /// Gets BMX version info for display
    func getVersionInfo() async -> String? {
        guard let bmx = bmxTranswrapPath else { return nil }

        let process = Process()
        process.executableURL = bmx
        process.arguments = ["-v"]

        // Set library path using centralized resolver
        process.environment = toolResolver.bmxEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }

        return nil
    }
}
