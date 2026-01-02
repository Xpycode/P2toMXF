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

    private var currentProcess: Process?
    private(set) var isCancelling = false

    // MARK: - Tool Paths

    /// Path to the bundled FFmpeg binary
    var ffmpegPath: URL? {
        if let bundledPath = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            return bundledPath
        }
        let homebrewPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Path to ffprobe (bundled or system)
    var ffprobePath: URL? {
        if let bundledPath = Bundle.main.url(forResource: "ffprobe", withExtension: nil) {
            return bundledPath
        }
        let homebrewPaths = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
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

    /// Fallback container info using ffmpeg -i
    private func getContainerInfoWithFFmpeg(
        fileURL: URL,
        logHandler: @escaping LogHandler
    ) async throws -> ContainerInfo {
        guard let ffmpeg = ffmpegPath else {
            throw VerificationError.ffmpegNotFound
        }

        // ffmpeg -i outputs to stderr
        let args = ["-i", fileURL.path]

        do {
            _ = try await runProcess(at: ffmpeg, arguments: args, logHandler: { _ in })
        } catch {
            // ffmpeg -i always "fails" since there's no output, but we get info from stderr
        }

        // Return basic info - actual parsing would require stderr capture
        return ContainerInfo(
            format: fileURL.pathExtension.uppercased(),
            streams: 2,  // Assume video + audio
            duration: "--:--:--",
            durationSeconds: 0,
            estimatedFrames: 0,
            frameRate: 25.0
        )
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

        // Use hardware acceleration if available (VideoToolbox on macOS)
        var args = [String]()

        // Try hardware decode first
        args.append(contentsOf: ["-hwaccel", "videotoolbox"])
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
            throw VerificationError.cancelled
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessDecodeResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            var lastFrameCount = 0
            var lastSpeed: String?
            var errorOutput = ""

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }

                errorOutput += str

                // Parse frame count and speed from FFmpeg output
                // Format: "frame=  123 fps= 45.6 ... speed=12.3x"
                if let frameMatch = str.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
                    let frameStr = str[frameMatch]
                        .replacingOccurrences(of: "frame=", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let frame = Int(frameStr) {
                        lastFrameCount = frame

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
                                lastSpeed = speedStr
                            }
                        }

                        var statusParts = ["Frame \(frame)"]
                        if expectedFrames > 0 {
                            statusParts[0] = "Frame \(frame)/\(expectedFrames)"
                        }
                        if let speed = lastSpeed {
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

            process.terminationHandler = { [weak self] proc in
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let wasCancelled = self?.isCancelling ?? false

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: ProcessDecodeResult(
                        frames: lastFrameCount,
                        speed: lastSpeed
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
