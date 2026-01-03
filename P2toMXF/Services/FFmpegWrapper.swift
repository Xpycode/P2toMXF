import Foundation
import AppKit

/// Wrapper for FFmpeg operations, specifically for combining P2 MXF files
/// Uses BMX for P2 OPAtom -> OP1a rewrapping, then FFmpeg for concatenation
class FFmpegWrapper {

    enum FFmpegError: LocalizedError {
        case ffmpegNotFound
        case bmxNotFound
        case conversionFailed(String)
        case invalidInput(String)
        case cancelled  // User-initiated cancellation

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg binary not found in app bundle. Please add ffmpeg to Resources."
            case .bmxNotFound:
                return "BMX tools not found in app bundle. Please add bmxtranswrap to Resources."
            case .conversionFailed(let msg):
                return "Conversion failed: \(msg)"
            case .invalidInput(let msg):
                return "Invalid input: \(msg)"
            case .cancelled:
                return "Conversion was cancelled"
            }
        }
    }

    /// Progress callback: (progress 0.0-1.0, current status message)
    typealias ProgressHandler = (Double, String) -> Void
    /// Log callback for console output
    typealias LogHandler = (String) -> Void
    /// Metrics callback for detailed progress info
    typealias MetricsHandler = (ProgressMetrics) -> Void

    /// Parsed metrics from FFmpeg output
    struct FFmpegOutputMetrics {
        var frame: Int?
        var fps: Double?
        var speed: String?
        var time: String?
        var bitrate: String?
        var size: String?
    }

    private var currentProcess: Process?
    private let cancelLock = NSLock()
    private var _isCancelling = false
    /// Thread-safe cancellation flag (accessed from main thread and process termination handler)
    private var isCancelling: Bool {
        get { cancelLock.withLock { _isCancelling } }
        set { cancelLock.withLock { _isCancelling = newValue } }
    }
    private let bmxWrapper = BMXWrapper()

    /// Path to the bundled FFmpeg binary
    var ffmpegPath: URL? {
        // First check app bundle Resources
        if let bundledPath = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            return bundledPath
        }

        // Fallback: check common Homebrew locations
        let homebrewPaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon
            "/usr/local/bin/ffmpeg"       // Intel
        ]

        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    /// Checks if FFmpeg is available
    var isFFmpegAvailable: Bool {
        ffmpegPath != nil
    }

    /// Converts a P2 clip to a single MXF file
    /// - Parameters:
    ///   - clip: The P2 clip to convert
    ///   - outputURL: Destination path for the output MXF
    ///   - settings: Conversion settings
    ///   - progress: Progress callback
    ///   - logHandler: Log callback for console output
    func convertClip(
        _ clip: P2Clip,
        to outputURL: URL,
        settings: ConversionSettings,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in }
    ) async throws {
        guard let ffmpeg = ffmpegPath else {
            logHandler("ERROR: FFmpeg not found!")
            throw FFmpegError.ffmpegNotFound
        }

        guard !clip.videoFiles.isEmpty else {
            logHandler("ERROR: No video files found for clip")
            throw FFmpegError.invalidInput("No video files found for clip")
        }

        progress(0.0, "Preparing conversion...")

        // Build FFmpeg arguments
        var args = [String]()

        // Input files
        for videoFile in clip.videoFiles {
            args.append(contentsOf: ["-i", videoFile.path])
        }
        for audioFile in clip.audioFiles {
            args.append(contentsOf: ["-i", audioFile.path])
        }

        // Stream copy (no re-encoding) for video
        args.append(contentsOf: ["-c:v", "copy"])

        // Audio handling based on settings
        switch settings.audioMapping {
        case .allChannels:
            args.append(contentsOf: ["-c:a", "copy"])
        case .stereoMix:
            // Mix down to stereo, channels 1-2
            args.append(contentsOf: ["-c:a", "pcm_s24le", "-ac", "2"])
        case .mono:
            // Single channel
            args.append(contentsOf: ["-c:a", "pcm_s24le", "-ac", "1"])
        }

        // Map all streams
        let totalInputs = clip.videoFiles.count + clip.audioFiles.count
        for i in 0..<totalInputs {
            args.append(contentsOf: ["-map", "\(i)"])
        }

        // Preserve timecode if available and requested
        if settings.preserveTimecode && !clip.startTimecode.isEmpty {
            args.append(contentsOf: ["-timecode", clip.startTimecode])
        }

        // Output format and path
        args.append(contentsOf: ["-f", "mxf"])
        args.append(contentsOf: ["-y"])  // Overwrite output
        args.append(outputURL.path)

        // Log the command
        let commandStr = "ffmpeg " + args.joined(separator: " ")
        logHandler("Command: \(commandStr)")

        progress(0.1, "Starting FFmpeg...")

        // Execute FFmpeg
        try await runFFmpeg(at: ffmpeg, arguments: args, progress: progress, logHandler: logHandler)

        progress(1.0, "Conversion complete")
    }

    /// Rewraps a single P2 clip to a self-contained MXF or MOV file
    /// Uses BMX for proper MXF handling, falls back to FFmpeg for MOV output or when audio mixing is needed
    /// - Parameters:
    ///   - clip: The P2 clip to rewrap
    ///   - outputURL: Destination path for the output file
    ///   - outputFormat: "mxf" or "mov"
    ///   - settings: Conversion settings
    ///   - progress: Progress callback
    ///   - logHandler: Log callback for console output
    func rewrapSingleClip(
        _ clip: P2Clip,
        to outputURL: URL,
        outputFormat: String = "mxf",
        settings: ConversionSettings,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in },
        metricsHandler: MetricsHandler? = nil
    ) async throws {
        // Reset cancellation state at start of new operation
        resetCancellation()
        bmxWrapper.resetCancellation()

        // Calculate total frames for this clip
        let totalFrames = clip.durationFrames

        // Determine if we need audio mixing (BMX doesn't support this)
        let needsAudioMixing = settings.audioMapping != .allChannels

        if outputFormat == "mxf" && bmxWrapper.isBMXAvailable && !needsAudioMixing {
            // Use BMX for MXF output (handles P2 index tables correctly)
            logHandler("Using BMX for MXF rewrap...")
            logHandler("Total frames: \(totalFrames)")
            try await bmxWrapper.rewrapClip(clip, to: outputURL, progress: progress, logHandler: logHandler)
        } else {
            // Use FFmpeg for MOV output, or when audio mixing is needed
            if needsAudioMixing && outputFormat == "mxf" {
                logHandler("Note: Audio mixing requires FFmpeg (BMX doesn't support audio remapping)")
                logHandler("Using FFmpeg for MXF with audio mix...")
            } else {
                logHandler("Using FFmpeg for \(outputFormat.uppercased()) rewrap...")
            }
            logHandler("Total frames: \(totalFrames)")

            // Adjust output format in args based on actual format
            var adjustedSettings = settings
            // Note: rewrapClipWithFFmpeg handles the format internally based on outputURL extension

            try await rewrapClipWithFFmpeg(
                clip,
                to: outputURL,
                settings: adjustedSettings,
                totalFrames: totalFrames,
                progress: progress,
                logHandler: logHandler,
                metricsHandler: metricsHandler
            )
        }
    }

    /// Rewraps a clip using FFmpeg (for MOV output)
    private func rewrapClipWithFFmpeg(
        _ clip: P2Clip,
        to outputURL: URL,
        settings: ConversionSettings,
        totalFrames: Int? = nil,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler,
        metricsHandler: MetricsHandler? = nil
    ) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw FFmpegError.ffmpegNotFound
        }

        var args = [String]()

        // Input: video file
        for videoFile in clip.videoFiles {
            args.append(contentsOf: ["-i", videoFile.path])
        }
        // Input: audio files
        for audioFile in clip.audioFiles {
            args.append(contentsOf: ["-i", audioFile.path])
        }

        // Video: always stream copy
        args.append(contentsOf: ["-c:v", "copy"])

        // Audio handling based on mapping setting
        let audioCount = clip.audioFiles.count
        switch settings.audioMapping {
        case .allChannels:
            // Stream copy all audio channels
            args.append(contentsOf: ["-c:a", "copy"])
            // Map video from first input
            args.append(contentsOf: ["-map", "0:v:0"])
            // Map audio from subsequent inputs
            for i in 0..<audioCount {
                args.append(contentsOf: ["-map", "\(i + 1):a:0"])
            }

        case .stereoMix:
            // Mix P2's 4 mono channels to stereo: ch1+ch3 → left, ch2+ch4 → right
            // P2 typically records: ch1-2 = camera mics, ch3-4 = external inputs
            if audioCount >= 4 {
                // Use filter_complex to merge and pan to stereo
                args.append(contentsOf: [
                    "-filter_complex",
                    "[1:a][2:a][3:a][4:a]amerge=inputs=4,pan=stereo|c0=c0+c2|c1=c1+c3[aout]"
                ])
                args.append(contentsOf: ["-map", "0:v:0", "-map", "[aout]"])
                args.append(contentsOf: ["-c:a", "pcm_s24le"])  // Professional quality audio
            } else if audioCount >= 2 {
                // Fallback for 2 channels: just merge them
                args.append(contentsOf: [
                    "-filter_complex",
                    "[1:a][2:a]amerge=inputs=2[aout]"
                ])
                args.append(contentsOf: ["-map", "0:v:0", "-map", "[aout]"])
                args.append(contentsOf: ["-c:a", "pcm_s24le"])
            } else {
                // Single channel - duplicate to stereo
                args.append(contentsOf: ["-map", "0:v:0", "-map", "1:a:0"])
                args.append(contentsOf: ["-c:a", "pcm_s24le", "-ac", "2"])
            }

        case .mono:
            // Mix all channels to mono
            if audioCount >= 4 {
                args.append(contentsOf: [
                    "-filter_complex",
                    "[1:a][2:a][3:a][4:a]amerge=inputs=4,pan=mono|c0=0.25*c0+0.25*c1+0.25*c2+0.25*c3[aout]"
                ])
                args.append(contentsOf: ["-map", "0:v:0", "-map", "[aout]"])
                args.append(contentsOf: ["-c:a", "pcm_s24le"])
            } else if audioCount >= 2 {
                args.append(contentsOf: [
                    "-filter_complex",
                    "[1:a][2:a]amerge=inputs=2,pan=mono|c0=0.5*c0+0.5*c1[aout]"
                ])
                args.append(contentsOf: ["-map", "0:v:0", "-map", "[aout]"])
                args.append(contentsOf: ["-c:a", "pcm_s24le"])
            } else {
                args.append(contentsOf: ["-map", "0:v:0", "-map", "1:a:0"])
                args.append(contentsOf: ["-c:a", "pcm_s24le", "-ac", "1"])
            }
        }

        // Timecode
        if settings.preserveTimecode && !clip.startTimecode.isEmpty {
            args.append(contentsOf: ["-timecode", clip.startTimecode])
        }

        // Output format based on file extension
        let outputFormat = outputURL.pathExtension.lowercased() == "mxf" ? "mxf" : "mov"
        args.append(contentsOf: ["-f", outputFormat, "-y", outputURL.path])

        logHandler("Command: ffmpeg " + args.joined(separator: " "))
        try await runFFmpeg(
            at: ffmpeg,
            arguments: args,
            totalFrames: totalFrames,
            progress: progress,
            logHandler: logHandler,
            metricsHandler: metricsHandler
        )
    }

    /// Merges multiple P2 clips into a single MXF file
    /// Uses BMX to rewrap each clip first, then FFmpeg to concatenate
    /// - Parameters:
    ///   - clips: Array of P2 clips to merge (should be sorted by timecode)
    ///   - outputURL: Destination path for the output MXF
    ///   - settings: Conversion settings
    ///   - progress: Progress callback
    ///   - logHandler: Log callback for console output
    ///   - metricsHandler: Optional callback for detailed progress metrics
    func mergeClips(
        _ clips: [P2Clip],
        to outputURL: URL,
        settings: ConversionSettings,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in },
        metricsHandler: MetricsHandler? = nil
    ) async throws {
        // Reset cancellation state at start of new operation
        resetCancellation()
        bmxWrapper.resetCancellation()

        guard let ffmpeg = ffmpegPath else {
            logHandler("ERROR: FFmpeg not found!")
            throw FFmpegError.ffmpegNotFound
        }

        guard !clips.isEmpty else {
            throw FFmpegError.invalidInput("No clips to merge")
        }

        // For single clip, just rewrap directly
        if clips.count == 1 {
            try await rewrapSingleClip(
                clips[0],
                to: outputURL,
                outputFormat: outputURL.pathExtension.lowercased(),
                settings: settings,
                progress: progress,
                logHandler: logHandler
            )
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("P2toMXF_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Determine if we need audio mixing (BMX doesn't support this)
        let needsAudioMixing = settings.audioMapping != .allChannels

        if needsAudioMixing {
            progress(0.0, "Phase 1: Rewrapping clips with FFmpeg (audio mixing)...")
            logHandler("=== Phase 1: FFmpeg Rewrap with Audio Mixing ===")
            logHandler("Audio mapping: \(settings.audioMapping.rawValue)")
        } else {
            progress(0.0, "Phase 1: Rewrapping clips with BMX...")
            logHandler("=== Phase 1: BMX Rewrap (P2 OPAtom -> OP1a MXF) ===")
        }

        // Phase 1: Rewrap each P2 clip
        var rewrappedFiles: [URL] = []

        // Use FFmpeg when audio mixing is needed, BMX otherwise
        if bmxWrapper.isBMXAvailable && !needsAudioMixing {
            for (index, clip) in clips.enumerated() {
                // Check for cancellation before starting each clip
                try Task.checkCancellation()

                let clipProgress = Double(index) / Double(clips.count) * 0.6  // 60% for rewrap phase
                progress(clipProgress, "Rewrapping clip \(index + 1) of \(clips.count): \(clip.clipName)")
                logHandler("Rewrapping: \(clip.clipName)")

                let outputFile = tempDir.appendingPathComponent("\(clip.clipName).mxf")
                try await bmxWrapper.rewrapClip(clip, to: outputFile, progress: { _, _ in }, logHandler: logHandler)
                rewrappedFiles.append(outputFile)
            }
        } else {
            // Use FFmpeg for audio mixing or as fallback when BMX unavailable
            if !bmxWrapper.isBMXAvailable {
                logHandler("BMX not available, falling back to FFmpeg")
            }
            for (index, clip) in clips.enumerated() {
                // Check for cancellation before starting each clip
                try Task.checkCancellation()

                let clipProgress = Double(index) / Double(clips.count) * 0.6
                progress(clipProgress, "Rewrapping clip \(index + 1) of \(clips.count): \(clip.clipName)")

                // Use MOV for intermediate files when audio mixing (better compatibility)
                let ext = needsAudioMixing ? "mov" : "mov"
                let outputFile = tempDir.appendingPathComponent("\(clip.clipName).\(ext)")
                try await rewrapClipWithFFmpeg(
                    clip,
                    to: outputFile,
                    settings: settings,
                    totalFrames: clip.durationFrames,
                    progress: { _, _ in },
                    logHandler: logHandler
                )
                rewrappedFiles.append(outputFile)
            }
        }

        // Check for cancellation before starting concatenation phase
        try Task.checkCancellation()

        progress(0.6, "Phase 2: Concatenating with FFmpeg...")
        logHandler("=== Phase 2: FFmpeg Concatenation ===")

        // Phase 2: Use FFmpeg concat demuxer on the rewrapped files
        let concatFile = tempDir.appendingPathComponent("concat_list.txt")
        var concatContent = ""
        for file in rewrappedFiles {
            concatContent += "file '\(file.path)'\n"
        }
        try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)
        logHandler("Concat list: \(rewrappedFiles.count) files")

        // Build FFmpeg concat arguments
        var args = [String]()
        args.append(contentsOf: ["-f", "concat", "-safe", "0", "-i", concatFile.path])

        // Stream copy (the rewrapped files are now compatible)
        args.append(contentsOf: ["-c", "copy"])

        // Map all streams
        args.append(contentsOf: ["-map", "0:v"])
        args.append(contentsOf: ["-map", "0:a"])

        // Timecode from first clip
        if settings.preserveTimecode, let firstClip = clips.first, !firstClip.startTimecode.isEmpty {
            args.append(contentsOf: ["-timecode", firstClip.startTimecode])
            logHandler("Using timecode from first clip: \(firstClip.startTimecode)")
        }

        // Output format based on extension
        let outputExt = outputURL.pathExtension.lowercased()
        if outputExt == "mxf" {
            args.append(contentsOf: ["-f", "mxf"])
        } else {
            args.append(contentsOf: ["-f", "mov"])
        }
        args.append(contentsOf: ["-y", outputURL.path])

        logHandler("Command: ffmpeg " + args.joined(separator: " "))

        // Calculate total frames for accurate progress
        let totalFrames = clips.reduce(0) { $0 + $1.durationFrames }
        logHandler("Total frames to concatenate: \(totalFrames)")

        try await runFFmpeg(
            at: ffmpeg,
            arguments: args,
            totalFrames: totalFrames,
            progress: { p, msg in
                progress(0.6 + p * 0.4, msg)  // Scale to remaining 40%
            },
            logHandler: logHandler,
            metricsHandler: metricsHandler.map { handler in
                { metrics in
                    // Adjust progress to account for Phase 1 (60%)
                    var adjustedMetrics = metrics
                    adjustedMetrics.progress = 0.6 + metrics.progress * 0.4
                    adjustedMetrics.totalClips = clips.count
                    handler(adjustedMetrics)
                }
            }
        )

        progress(1.0, "Merge complete")
        logHandler("=== Merge Complete ===")
    }

    /// Parses FFmpeg progress output to extract metrics
    /// FFmpeg outputs lines like: "frame=  123 fps= 24.5 q=28.0 size=   1234kB time=00:01:23.45 bitrate= 123.4kbits/s speed=12.3x"
    private func parseFFmpegOutput(_ output: String) -> FFmpegOutputMetrics {
        var metrics = FFmpegOutputMetrics()

        // Parse frame=
        if let match = output.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
            let frameStr = output[match].replacingOccurrences(of: "frame=", with: "").trimmingCharacters(in: .whitespaces)
            metrics.frame = Int(frameStr)
        }

        // Parse fps=
        if let match = output.range(of: #"fps=\s*([\d.]+)"#, options: .regularExpression) {
            let fpsStr = output[match].replacingOccurrences(of: "fps=", with: "").trimmingCharacters(in: .whitespaces)
            metrics.fps = Double(fpsStr)
        }

        // Parse speed= (e.g., "12.5x" or "N/A")
        if let match = output.range(of: #"speed=\s*([\d.]+x|N/A)"#, options: .regularExpression) {
            let speedStr = output[match].replacingOccurrences(of: "speed=", with: "").trimmingCharacters(in: .whitespaces)
            if speedStr != "N/A" {
                metrics.speed = speedStr
            }
        }

        // Parse time= (e.g., "00:01:23.45")
        if let match = output.range(of: #"time=\s*([\d:.]+)"#, options: .regularExpression) {
            let timeStr = output[match].replacingOccurrences(of: "time=", with: "").trimmingCharacters(in: .whitespaces)
            if !timeStr.starts(with: "-") {  // Ignore negative times
                metrics.time = timeStr
            }
        }

        // Parse bitrate=
        if let match = output.range(of: #"bitrate=\s*([\d.]+\s*\w+/s)"#, options: .regularExpression) {
            let bitrateStr = output[match].replacingOccurrences(of: "bitrate=", with: "").trimmingCharacters(in: .whitespaces)
            metrics.bitrate = bitrateStr
        }

        // Parse size=
        if let match = output.range(of: #"size=\s*([\d.]+\s*\w+)"#, options: .regularExpression) {
            let sizeStr = output[match].replacingOccurrences(of: "size=", with: "").trimmingCharacters(in: .whitespaces)
            metrics.size = sizeStr
        }

        return metrics
    }

    /// Thread-safe container for collecting FFmpeg stderr output
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

    /// Runs FFmpeg with the given arguments
    /// - Parameters:
    ///   - ffmpegURL: Path to FFmpeg binary
    ///   - arguments: Command line arguments
    ///   - totalFrames: Optional total frame count for accurate progress (if known)
    ///   - progress: Progress callback (0.0-1.0, status message)
    ///   - logHandler: Log output callback
    ///   - metricsHandler: Optional callback for detailed metrics (speed, fps, etc.)
    private func runFFmpeg(
        at ffmpegURL: URL,
        arguments: [String],
        totalFrames: Int? = nil,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler,
        metricsHandler: MetricsHandler? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = ffmpegURL
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let errorCollector = OutputCollector()

            // FFmpeg outputs progress info to stderr
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    errorCollector.append(str)

                    // Log FFmpeg output (but not the repetitive progress lines)
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.starts(with: "frame=") {
                        DispatchQueue.main.async {
                            logHandler("FFmpeg: \(trimmed)")
                        }
                    }

                    // Parse metrics from FFmpeg output
                    guard let self = self else { return }
                    let metrics = self.parseFFmpegOutput(str)

                    if let frame = metrics.frame {
                        // Calculate progress based on frame count
                        let estimatedProgress: Double
                        if let total = totalFrames, total > 0 {
                            estimatedProgress = min(0.99, Double(frame) / Double(total))
                        } else {
                            // Fallback: estimate based on 1000 frames
                            estimatedProgress = min(0.9, Double(frame) / 1000.0)
                        }

                        // Build status message with metrics
                        var statusParts: [String] = []
                        if let total = totalFrames {
                            statusParts.append("Frame \(frame)/\(total)")
                        } else {
                            statusParts.append("Frame \(frame)")
                        }
                        if let speed = metrics.speed {
                            statusParts.append(speed)
                        } else if let fps = metrics.fps, fps > 0 {
                            statusParts.append(String(format: "%.0f fps", fps))
                        }

                        let statusMsg = statusParts.joined(separator: " • ")

                        DispatchQueue.main.async {
                            progress(estimatedProgress, statusMsg)

                            // Report detailed metrics if handler provided
                            if let handler = metricsHandler {
                                var progressMetrics = ProgressMetrics()
                                progressMetrics.progress = estimatedProgress
                                progressMetrics.phase = statusMsg
                                progressMetrics.currentFrame = frame
                                progressMetrics.totalFrames = totalFrames
                                progressMetrics.fps = metrics.fps
                                progressMetrics.speed = metrics.speed
                                progressMetrics.processedTime = metrics.time
                                handler(progressMetrics)
                            }
                        }
                    }
                }
            }

            process.terminationHandler = { [weak self] proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let wasCancelled = self?.isCancelling ?? false

                DispatchQueue.main.async {
                    logHandler("FFmpeg exit code: \(proc.terminationStatus)\(wasCancelled ? " (cancelled)" : "")")
                }

                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else if wasCancelled {
                    // Process was terminated by user cancellation
                    continuation.resume(throwing: FFmpegError.cancelled)
                } else {
                    let errorOutput = errorCollector.output
                    DispatchQueue.main.async {
                        logHandler("FFmpeg error output: \(errorOutput)")
                    }
                    continuation.resume(throwing: FFmpegError.conversionFailed(errorOutput))
                }
            }

            self.currentProcess = process

            DispatchQueue.main.async {
                logHandler("Starting process: \(ffmpegURL.path)")
            }

            do {
                try process.run()
                DispatchQueue.main.async {
                    logHandler("Process started with PID: \(process.processIdentifier)")
                }
            } catch {
                DispatchQueue.main.async {
                    logHandler("Failed to start process: \(error.localizedDescription)")
                }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Cancels any running conversion (both FFmpeg and BMX processes)
    /// Uses process group killing to ensure child processes are also terminated
    func cancelConversion() {
        isCancelling = true

        if let process = currentProcess, process.isRunning {
            let pid = process.processIdentifier

            // Kill the entire process group to catch any child processes
            // getpgid returns the process group ID; kill with negative PID targets the group
            let pgid = getpgid(pid)
            if pgid > 0 {
                kill(-pgid, SIGTERM)  // Negative PID = kill process group
            }

            // Also terminate via Swift API as backup
            process.terminate()
        }

        currentProcess = nil
        bmxWrapper.cancel()
    }

    /// Resets cancellation state - call before starting new conversion
    func resetCancellation() {
        isCancelling = false
    }

    // MARK: - Frame Extraction for Thumbnails

    /// Extracts a single frame from a video file at the specified timestamp
    /// - Parameters:
    ///   - videoURL: Path to the video file (MP4, MXF, etc.)
    ///   - timestamp: Time in seconds to extract the frame
    ///   - maxWidth: Maximum width for the output image (maintains aspect ratio)
    /// - Returns: NSImage if successful, nil otherwise
    func extractFrame(from videoURL: URL, atSeconds timestamp: Double, maxWidth: Int = 320) async -> NSImage? {
        guard let ffmpeg = ffmpegPath else { return nil }

        // Use -ss before -i for fast seeking
        // Output JPEG to stdout via pipe
        let args = [
            "-ss", String(format: "%.3f", timestamp),
            "-i", videoURL.path,
            "-frames:v", "1",
            "-vf", "scale=\(maxWidth):-1",  // Scale to maxWidth, maintain aspect ratio
            "-q:v", "2",                      // Good quality JPEG
            "-f", "image2pipe",
            "-vcodec", "mjpeg",
            "-"                               // Output to stdout
        ]

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = args

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let imageData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !imageData.isEmpty, let image = NSImage(data: imageData) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Gets FFmpeg version info for display
    func getVersionInfo() async -> String? {
        guard let ffmpeg = ffmpegPath else { return nil }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Extract first line (version info)
                return output.components(separatedBy: .newlines).first
            }
        } catch {
            return nil
        }

        return nil
    }
}
