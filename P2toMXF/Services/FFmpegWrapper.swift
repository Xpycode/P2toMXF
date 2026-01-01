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
            }
        }
    }

    /// Progress callback: (progress 0.0-1.0, current status message)
    typealias ProgressHandler = (Double, String) -> Void
    /// Log callback for console output
    typealias LogHandler = (String) -> Void

    private var currentProcess: Process?
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
    /// Uses BMX for proper MXF handling, falls back to FFmpeg for MOV output
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
        logHandler: @escaping LogHandler = { _ in }
    ) async throws {
        if outputFormat == "mxf" && bmxWrapper.isBMXAvailable {
            // Use BMX for MXF output (handles P2 index tables correctly)
            logHandler("Using BMX for MXF rewrap...")
            try await bmxWrapper.rewrapClip(clip, to: outputURL, progress: progress, logHandler: logHandler)
        } else {
            // Use FFmpeg for MOV output (stream copy works fine)
            logHandler("Using FFmpeg for MOV rewrap...")
            try await rewrapClipWithFFmpeg(clip, to: outputURL, settings: settings, progress: progress, logHandler: logHandler)
        }
    }

    /// Rewraps a clip using FFmpeg (for MOV output)
    private func rewrapClipWithFFmpeg(
        _ clip: P2Clip,
        to outputURL: URL,
        settings: ConversionSettings,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
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

        // Stream copy (no re-encoding)
        args.append(contentsOf: ["-c:v", "copy", "-c:a", "copy"])

        // Map video from first input
        args.append(contentsOf: ["-map", "0:v:0"])
        // Map audio from subsequent inputs
        for i in 0..<clip.audioFiles.count {
            args.append(contentsOf: ["-map", "\(i + 1):a:0"])
        }

        // Timecode
        if settings.preserveTimecode && !clip.startTimecode.isEmpty {
            args.append(contentsOf: ["-timecode", clip.startTimecode])
        }

        // Output
        args.append(contentsOf: ["-f", "mov", "-y", outputURL.path])

        logHandler("Command: ffmpeg " + args.joined(separator: " "))
        try await runFFmpeg(at: ffmpeg, arguments: args, progress: progress, logHandler: logHandler)
    }

    /// Merges multiple P2 clips into a single MXF file
    /// Uses BMX to rewrap each clip first, then FFmpeg to concatenate
    /// - Parameters:
    ///   - clips: Array of P2 clips to merge (should be sorted by timecode)
    ///   - outputURL: Destination path for the output MXF
    ///   - settings: Conversion settings
    ///   - progress: Progress callback
    ///   - logHandler: Log callback for console output
    func mergeClips(
        _ clips: [P2Clip],
        to outputURL: URL,
        settings: ConversionSettings,
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler = { _ in }
    ) async throws {
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

        progress(0.0, "Phase 1: Rewrapping clips with BMX...")
        logHandler("=== Phase 1: BMX Rewrap (P2 OPAtom -> OP1a MXF) ===")

        // Phase 1: Use BMX to rewrap each P2 clip to OP1a MXF
        var rewrappedFiles: [URL] = []

        if bmxWrapper.isBMXAvailable {
            for (index, clip) in clips.enumerated() {
                let clipProgress = Double(index) / Double(clips.count) * 0.6  // 60% for rewrap phase
                progress(clipProgress, "Rewrapping clip \(index + 1) of \(clips.count): \(clip.clipName)")
                logHandler("Rewrapping: \(clip.clipName)")

                let outputFile = tempDir.appendingPathComponent("\(clip.clipName).mxf")
                try await bmxWrapper.rewrapClip(clip, to: outputFile, progress: { _, _ in }, logHandler: logHandler)
                rewrappedFiles.append(outputFile)
            }
        } else {
            // Fallback: rewrap to MOV with FFmpeg
            logHandler("BMX not available, falling back to FFmpeg MOV rewrap")
            for (index, clip) in clips.enumerated() {
                let clipProgress = Double(index) / Double(clips.count) * 0.6
                progress(clipProgress, "Rewrapping clip \(index + 1) of \(clips.count): \(clip.clipName)")

                let outputFile = tempDir.appendingPathComponent("\(clip.clipName).mov")
                try await rewrapClipWithFFmpeg(clip, to: outputFile, settings: settings, progress: { _, _ in }, logHandler: logHandler)
                rewrappedFiles.append(outputFile)
            }
        }

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

        try await runFFmpeg(at: ffmpeg, arguments: args, progress: { p, msg in
            progress(0.6 + p * 0.4, msg)  // Scale to remaining 40%
        }, logHandler: logHandler)

        progress(1.0, "Merge complete")
        logHandler("=== Merge Complete ===")
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
    private func runFFmpeg(
        at ffmpegURL: URL,
        arguments: [String],
        progress: @escaping ProgressHandler,
        logHandler: @escaping LogHandler
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
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    errorCollector.append(str)

                    // Log FFmpeg output
                    DispatchQueue.main.async {
                        logHandler("FFmpeg: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }

                    // Parse progress from FFmpeg output
                    // FFmpeg outputs lines like: "frame=  123 fps= 24 ..."
                    if let frameMatch = str.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
                        let frameStr = str[frameMatch].replacingOccurrences(of: "frame=", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let frame = Int(frameStr) {
                            // Estimate progress (assuming ~1000 frames typical)
                            let estimatedProgress = min(0.9, Double(frame) / 1000.0)
                            DispatchQueue.main.async {
                                progress(0.1 + estimatedProgress * 0.8, "Merging frame \(frame)...")
                            }
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                DispatchQueue.main.async {
                    logHandler("FFmpeg exit code: \(proc.terminationStatus)")
                }

                if proc.terminationStatus == 0 {
                    continuation.resume()
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

    /// Cancels any running conversion
    func cancelConversion() {
        currentProcess?.terminate()
        currentProcess = nil
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
