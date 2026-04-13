import Foundation

/// Service for verifying video files by decoding them
/// Uses FFmpeg to perform container validation and full decode tests
class VerificationService {

    enum VerificationError: LocalizedError {
        case ffmpegNotFound
        case ffprobeNotFound
        case fileNotFound(String)
        case containerInvalid(String)
        case decodeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg binary not found in app bundle"
            case .ffprobeNotFound:
                return "FFprobe binary not found in app bundle"
            case .fileNotFound(let path):
                return "File not found: \(path)"
            case .containerInvalid(let msg):
                return "Invalid container: \(msg)"
            case .decodeFailed(let msg):
                return "Decode failed: \(msg)"
            case .cancelled:
                return "Verification was cancelled"
            }
        }
    }

    /// Progress callback: (progress 0.0-1.0, current status message)
    typealias ProgressHandler = (Double, String) -> Void
    /// Log callback for console output
    typealias LogHandler = (String) -> Void

    private var _currentProcess: Process?
    private let cancelLock = NSLock()
    private var _isCancelling = false

    /// Thread-safe access to the current process (read/written from multiple threads)
    private var currentProcess: Process? {
        get { cancelLock.withLock { _currentProcess } }
        set { cancelLock.withLock { _currentProcess = newValue } }
    }
    private(set) var isCancelling: Bool {
        get { cancelLock.withLock { _isCancelling } }
        set { cancelLock.withLock { _isCancelling = newValue } }
    }
    private let toolResolver = BundledToolResolver.shared

    // MARK: - Tool Paths

    /// Path to the bundled FFmpeg binary
    var ffmpegPath: URL? {
        toolResolver.path(for: .ffmpeg)
    }

    /// Path to ffprobe (bundled or system)
    var ffprobePath: URL? {
        toolResolver.path(for: .ffprobe)
    }

    // MARK: - Public API

    /// Verifies a video file
    /// - Parameters:
    ///   - fileURL: Path to the video file to verify
    ///   - mode: Quick or Full verification
    ///   - expectedFrames: Expected frame count (for progress calculation)
    ///   - progress: Progress callback
    ///   - logHandler: Log output callback
    /// - Returns: VerificationResult with details
    func verify(
        fileURL: URL,
        mode: VerificationMode,
        expectedFrames: Int? = nil,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async throws -> VerificationResult {
        resetCancellation()

        let startTime = Date()

        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VerificationError.fileNotFound(fileURL.path)
        }

        logHandler("=== Verification Started ===")
        logHandler("File: \(fileURL.lastPathComponent)")
        logHandler("Mode: \(mode.rawValue)")

        // Step 1: Container validation (quick check with ffprobe)
        progress(0.0, "Checking container structure...")
        let containerInfo = try await validateContainer(fileURL: fileURL, logHandler: logHandler)
        logHandler("Container: \(containerInfo.format) • \(containerInfo.streams) streams • \(containerInfo.duration)")

        // Step 2: Decode verification
        let decodeResult: DecodeResult
        switch mode {
        case .quick:
            progress(0.1, "Quick decode test...")
            decodeResult = try await quickDecodeTest(
                fileURL: fileURL,
                duration: containerInfo.durationSeconds,
                progress: { p, msg in progress(0.1 + p * 0.9, msg) },
                logHandler: logHandler
            )
        case .full:
            progress(0.1, "Full decode verification...")
            decodeResult = try await fullDecodeTest(
                fileURL: fileURL,
                expectedFrames: expectedFrames ?? containerInfo.estimatedFrames,
                progress: { p, msg in progress(0.1 + p * 0.9, msg) },
                logHandler: logHandler
            )
        }

        let elapsed = Date().timeIntervalSince(startTime)

        let result = VerificationResult(
            fileURL: fileURL,
            passed: decodeResult.success,
            mode: mode,
            duration: elapsed,
            framesDecoded: decodeResult.framesDecoded,
            totalFrames: expectedFrames ?? containerInfo.estimatedFrames,
            decodingSpeed: decodeResult.speed,
            containerValid: true,
            errorMessage: decodeResult.errorMessage,
            verifiedAt: Date()
        )

        if result.passed {
            logHandler("=== Verification PASSED ===")
            logHandler(result.summary)
        } else {
            logHandler("=== Verification FAILED ===")
            logHandler(result.summary)
        }

        progress(1.0, result.passed ? "Verified" : "Failed")
        return result
    }

    /// Cancels any running verification
    func cancel() {
        isCancelling = true
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
        currentProcess = nil
    }

    func resetCancellation() {
        isCancelling = false
    }

    // MARK: - Container Validation

    struct ContainerInfo {
        let format: String
        let streams: Int
        let duration: String
        let durationSeconds: Double
        let estimatedFrames: Int
        let frameRate: Double
    }

    /// Validates container structure using ffprobe
    private func validateContainer(
        fileURL: URL,
        logHandler: @escaping LogHandler
    ) async throws -> ContainerInfo {
        guard let ffprobe = ffprobePath ?? ffmpegPath else {
            // Fall back to ffmpeg -i for basic info if ffprobe not available
            return try await getContainerInfoWithFFmpeg(fileURL: fileURL, logHandler: logHandler)
        }

        let args = [
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-of", "json",
            fileURL.path
        ]

        let output = try await runProcess(at: ffprobe, arguments: args, logHandler: logHandler)

        // Parse JSON output
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VerificationError.containerInvalid("Failed to parse container info")
        }

        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []

        let formatName = format["format_name"] as? String ?? "unknown"
        let durationStr = format["duration"] as? String ?? "0"
        let durationSeconds = Double(durationStr) ?? 0

        // Get frame rate from first video stream
        var frameRate = 25.0
        for stream in streams {
            if stream["codec_type"] as? String == "video" {
                if let rFrameRate = stream["r_frame_rate"] as? String {
                    let parts = rFrameRate.split(separator: "/")
                    if parts.count == 2,
                       let num = Double(parts[0]),
                       let den = Double(parts[1]),
                       den > 0 {
                        frameRate = num / den
                    }
                }
                break
            }
        }

        let estimatedFrames = Int(durationSeconds * frameRate)
        let formattedDuration = formatDuration(durationSeconds)

        return ContainerInfo(
            format: formatName.uppercased(),
            streams: streams.count,
            duration: formattedDuration,
            durationSeconds: durationSeconds,
            estimatedFrames: estimatedFrames,
            frameRate: frameRate
        )
    }

    /// Fallback container info using ffmpeg -i (when ffprobe is not available)
    /// Parses stderr output to extract real container information
    private func getContainerInfoWithFFmpeg(
        fileURL: URL,
        logHandler: @escaping LogHandler
    ) async throws -> ContainerInfo {
        guard let ffmpeg = ffmpegPath else {
            throw VerificationError.ffmpegNotFound
        }

        // ffmpeg -i outputs info to stderr (and "fails" because no output file specified)
        let stderrOutput = try await runProcessCapturingStderr(
            at: ffmpeg,
            arguments: ["-i", fileURL.path]
        )

        // Parse the output for container info
        return try parseFFmpegInfoOutput(stderrOutput, fileURL: fileURL, logHandler: logHandler)
    }

    /// Runs a process and captures stderr (for ffmpeg -i which outputs to stderr)
    private func runProcessCapturingStderr(
        at executable: URL,
        arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                // Note: ffmpeg -i always exits with status 1 (no output file), but that's expected
                continuation.resume(returning: errorOutput)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Parses ffmpeg -i output to extract container information
    private func parseFFmpegInfoOutput(
        _ output: String,
        fileURL: URL,
        logHandler: @escaping LogHandler
    ) throws -> ContainerInfo {
        // Extract format from "Input #0, format_name," line
        var format = fileURL.pathExtension.uppercased()
        if let formatMatch = output.range(of: #"Input #0, ([^,]+),"#, options: .regularExpression) {
            let matched = String(output[formatMatch])
            if let extracted = matched.components(separatedBy: ", ").dropFirst().first?.trimmingCharacters(in: .punctuationCharacters) {
                format = extracted.uppercased()
            }
        }

        // Extract duration from "Duration: HH:MM:SS.ms" line
        var durationSeconds: Double = 0
        var durationStr = "--:--:--"
        if let durationMatch = output.range(of: #"Duration: (\d{2}:\d{2}:\d{2}\.\d+)"#, options: .regularExpression) {
            let matched = String(output[durationMatch])
            if let timeStr = matched.components(separatedBy: ": ").last {
                durationStr = String(timeStr.prefix(8))  // HH:MM:SS
                durationSeconds = parseDurationToSeconds(timeStr)
            }
        }

        // Count streams by looking for "Stream #0:" lines
        let streamMatches = output.components(separatedBy: "Stream #0:")
        let streamCount = max(1, streamMatches.count - 1)

        // Extract frame rate from video stream line
        var frameRate = 25.0
        // Look for patterns like "25 fps", "50 fps", "29.97 fps"
        if let fpsMatch = output.range(of: #"(\d+(?:\.\d+)?)\s*fps"#, options: .regularExpression) {
            let fpsStr = String(output[fpsMatch]).replacingOccurrences(of: "fps", with: "").trimmingCharacters(in: .whitespaces)
            if let fps = Double(fpsStr), fps > 0 {
                frameRate = fps
            }
        }

        let estimatedFrames = Int(durationSeconds * frameRate)

        // Verify we got meaningful data (at least duration should be parsed)
        if durationSeconds == 0 && !output.contains("Duration:") {
            logHandler("Warning: Could not parse container info from ffmpeg output")
            logHandler("FFmpeg output: \(output.prefix(500))...")
            throw VerificationError.containerInvalid("Could not parse container information (ffprobe not available)")
        }

        return ContainerInfo(
            format: format,
            streams: streamCount,
            duration: durationStr,
            durationSeconds: durationSeconds,
            estimatedFrames: estimatedFrames,
            frameRate: frameRate
        )
    }

    /// Parses duration string "HH:MM:SS.ms" to seconds
    private func parseDurationToSeconds(_ durationStr: String) -> Double {
        let parts = durationStr.split(separator: ":")
        guard parts.count == 3 else { return 0 }

        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0

        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - Decode Tests

    struct DecodeResult {
        let success: Bool
        let framesDecoded: Int?
        let speed: String?
        let errorMessage: String?
    }

    /// Quick decode test - first and last 5 seconds
    private func quickDecodeTest(
        fileURL: URL,
        duration: Double,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async throws -> DecodeResult {
        guard let ffmpeg = ffmpegPath else {
            throw VerificationError.ffmpegNotFound
        }

        // Decode first 5 seconds
        logHandler("Decoding first 5 seconds...")
        progress(0.0, "Decoding start of file...")

        let startArgs = [
            "-t", "5",           // First 5 seconds
            "-i", fileURL.path,
            "-f", "null",
            "-"
        ]

        var totalFrames = 0
        var lastSpeed: String?

        do {
            let result = try await runDecodeProcess(
                at: ffmpeg,
                arguments: startArgs,
                progress: { p, msg in progress(p * 0.45, msg) },
                logHandler: logHandler
            )
            totalFrames += result.frames
            lastSpeed = result.speed
        } catch VerificationError.cancelled {
            throw VerificationError.cancelled
        } catch {
            return DecodeResult(
                success: false,
                framesDecoded: totalFrames,
                speed: lastSpeed,
                errorMessage: "Start decode failed: \(error.localizedDescription)"
            )
        }

        // Decode last 5 seconds (if file is long enough)
        if duration > 10 {
            logHandler("Decoding last 5 seconds...")
            progress(0.5, "Decoding end of file...")

            let seekTime = max(0, duration - 5)
            let endArgs = [
                "-ss", String(format: "%.2f", seekTime),
                "-i", fileURL.path,
                "-f", "null",
                "-"
            ]

            do {
                let result = try await runDecodeProcess(
                    at: ffmpeg,
                    arguments: endArgs,
                    progress: { p, msg in progress(0.5 + p * 0.45, msg) },
                    logHandler: logHandler
                )
                totalFrames += result.frames
                lastSpeed = result.speed ?? lastSpeed
            } catch VerificationError.cancelled {
                throw VerificationError.cancelled
            } catch {
                return DecodeResult(
                    success: false,
                    framesDecoded: totalFrames,
                    speed: lastSpeed,
                    errorMessage: "End decode failed: \(error.localizedDescription)"
                )
            }
        }

        return DecodeResult(
            success: true,
            framesDecoded: totalFrames,
            speed: lastSpeed,
            errorMessage: nil
        )
    }

    /// Full decode test - every frame
    private func fullDecodeTest(
        fileURL: URL,
        expectedFrames: Int,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async throws -> DecodeResult {
        guard let ffmpeg = ffmpegPath else {
            throw VerificationError.ffmpegNotFound
        }

        logHandler("Full decode: expecting ~\(expectedFrames) frames")

        // Try hardware decode first (VideoToolbox on macOS)
        let hardwareResult = await tryDecode(
            ffmpeg: ffmpeg,
            fileURL: fileURL,
            useHardware: true,
            expectedFrames: expectedFrames,
            progress: progress,
            logHandler: logHandler
        )

        // If hardware decode failed with VideoToolbox error, retry with software
        if !hardwareResult.success,
           let errorMsg = hardwareResult.errorMessage,
           errorMsg.contains("VideoToolbox") || errorMsg.contains("hwaccel") {
            logHandler("Hardware decode failed, retrying with software decode...")
            return await tryDecode(
                ffmpeg: ffmpeg,
                fileURL: fileURL,
                useHardware: false,
                expectedFrames: expectedFrames,
                progress: progress,
                logHandler: logHandler
            )
        }

        return hardwareResult
    }

    /// Attempts to decode a file with optional hardware acceleration
    private func tryDecode(
        ffmpeg: URL,
        fileURL: URL,
        useHardware: Bool,
        expectedFrames: Int,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async -> DecodeResult {
        var args = [String]()

        if useHardware {
            args.append(contentsOf: ["-hwaccel", "videotoolbox"])
        }
        args.append(contentsOf: ["-i", fileURL.path])
        args.append(contentsOf: ["-f", "null", "-"])

        do {
            let result = try await runDecodeProcess(
                at: ffmpeg,
                arguments: args,
                expectedFrames: expectedFrames,
                progress: progress,
                logHandler: logHandler
            )

            // Verify we decoded a reasonable number of frames
            let tolerance = 0.95  // Allow 5% tolerance
            let expectedMin = Int(Double(expectedFrames) * tolerance)

            if result.frames >= expectedMin {
                return DecodeResult(
                    success: true,
                    framesDecoded: result.frames,
                    speed: result.speed,
                    errorMessage: nil
                )
            } else {
                return DecodeResult(
                    success: false,
                    framesDecoded: result.frames,
                    speed: result.speed,
                    errorMessage: "Frame count mismatch: decoded \(result.frames), expected ~\(expectedFrames)"
                )
            }
        } catch VerificationError.cancelled {
            return DecodeResult(
                success: false,
                framesDecoded: nil,
                speed: nil,
                errorMessage: "Verification cancelled"
            )
        } catch {
            return DecodeResult(
                success: false,
                framesDecoded: nil,
                speed: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Process Execution

    struct ProcessDecodeResult {
        let frames: Int
        let speed: String?
    }

    /// Runs a decode process and tracks progress
    private func runDecodeProcess(
        at executable: URL,
        arguments: [String],
        expectedFrames: Int = 0,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
    ) async throws -> ProcessDecodeResult {
        /// Thread-safe container for mutable state shared across Process callbacks.
        /// Uses NSLock to protect against concurrent GCD pipe callback writes.
        final class DecodeState: @unchecked Sendable {
            private let lock = NSLock()
            private var _lastFrameCount = 0
            private var _lastSpeed: String?
            private var _errorOutput = ""

            var lastFrameCount: Int {
                get { lock.withLock { _lastFrameCount } }
                set { lock.withLock { _lastFrameCount = newValue } }
            }
            var lastSpeed: String? {
                get { lock.withLock { _lastSpeed } }
                set { lock.withLock { _lastSpeed = newValue } }
            }
            var errorOutput: String {
                get { lock.withLock { _errorOutput } }
                set { lock.withLock { _errorOutput = newValue } }
            }
            func appendError(_ str: String) {
                lock.withLock { _errorOutput += str }
            }
        }
        let state = DecodeState()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessDecodeResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self, state] handle in
                let data = handle.availableData
                guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }

                state.appendError(str)

                // Parse frame count and speed from FFmpeg output
                // Format: "frame=  123 fps= 45.6 ... speed=12.3x"
                if let frameMatch = str.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
                    let frameStr = str[frameMatch]
                        .replacingOccurrences(of: "frame=", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let frame = Int(frameStr) {
                        state.lastFrameCount = frame

                        let currentProgress: Double
                        if expectedFrames > 0 {
                            currentProgress = min(0.99, Double(frame) / Double(expectedFrames))
                        } else {
                            currentProgress = min(0.99, Double(frame) / 1000.0)
                        }

                        // Parse speed
                        if let speedMatch = str.range(of: #"speed=\s*([\d.]+x|N/A)"#, options: .regularExpression) {
                            let speedStr = str[speedMatch]
                                .replacingOccurrences(of: "speed=", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            if speedStr != "N/A" {
                                state.lastSpeed = speedStr
                            }
                        }

                        var statusParts = ["Frame \(frame)"]
                        if expectedFrames > 0 {
                            statusParts[0] = "Frame \(frame)/\(expectedFrames)"
                        }
                        if let speed = state.lastSpeed {
                            statusParts.append(speed)
                        }

                        DispatchQueue.main.async {
                            progress(currentProgress, statusParts.joined(separator: " • "))
                        }
                    }
                }

                // Check for cancellation
                if self?.isCancelling == true {
                    process.terminate()
                }
            }

            process.terminationHandler = { [weak self, state] proc in
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let wasCancelled = self?.isCancelling ?? false

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: ProcessDecodeResult(
                        frames: state.lastFrameCount,
                        speed: state.lastSpeed
                    ))
                } else if wasCancelled {
                    continuation.resume(throwing: VerificationError.cancelled)
                } else {
                    // FFmpeg returns non-zero on decode errors
                    continuation.resume(throwing: VerificationError.decodeFailed(
                        "Exit code \(proc.terminationStatus)"
                    ))
                }
            }

            self.currentProcess = process

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a simple process and returns stdout
    private func runProcess(
        at executable: URL,
        arguments: [String],
        logHandler: @escaping LogHandler
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { proc in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: VerificationError.containerInvalid(errorOutput))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
