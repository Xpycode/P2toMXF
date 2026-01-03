import Foundation

/// Represents a single P2 clip with its associated video, audio, and metadata
struct P2Clip: Identifiable, Hashable, Codable {
    let id: UUID
    let clipName: String
    let globalClipID: String
    let duration: String
    let startTimecode: String
    let frameRate: String
    let videoCodec: String
    let audioChannels: Int

    // File paths (stored as strings for Codable, converted to URLs via computed properties)
    private let videoFilePaths: [String]
    private let audioFilePaths: [String]
    private let metadataFilePath: String
    private let proxyFilePath: String?
    private let iconFilePath: String?

    // MARK: - URL Accessors

    var videoFiles: [URL] { videoFilePaths.map { URL(fileURLWithPath: $0) } }
    var audioFiles: [URL] { audioFilePaths.map { URL(fileURLWithPath: $0) } }
    var metadataFile: URL { URL(fileURLWithPath: metadataFilePath) }
    var proxyFile: URL? { proxyFilePath.map { URL(fileURLWithPath: $0) } }
    var iconFile: URL? { iconFilePath.map { URL(fileURLWithPath: $0) } }

    // MARK: - Initializers

    init(
        clipName: String,
        globalClipID: String,
        duration: String,
        startTimecode: String,
        frameRate: String,
        videoCodec: String,
        audioChannels: Int,
        videoFiles: [URL],
        audioFiles: [URL],
        metadataFile: URL,
        proxyFile: URL?,
        iconFile: URL?
    ) {
        self.id = UUID()
        self.clipName = clipName
        self.globalClipID = globalClipID
        self.duration = duration
        self.startTimecode = startTimecode
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioChannels = audioChannels
        self.videoFilePaths = videoFiles.map { $0.path }
        self.audioFilePaths = audioFiles.map { $0.path }
        self.metadataFilePath = metadataFile.path
        self.proxyFilePath = proxyFile?.path
        self.iconFilePath = iconFile?.path
    }

    var displayName: String {
        clipName.isEmpty ? globalClipID : clipName
    }

    /// Total file size of all source files (video + audio) in bytes
    var totalFileSize: Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        for file in videoFiles {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        for file in audioFiles {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// Frame rate as Double for calculations
    var frameRateDouble: Double {
        Double(frameRate) ?? 25.0
    }

    /// Duration in frames as Int
    var durationFrames: Int {
        Int(duration) ?? 0
    }

    /// Duration in seconds for thumbnail extraction
    var durationInSeconds: Double {
        guard frameRateDouble > 0 else { return 0 }
        return Double(durationFrames) / frameRateDouble
    }

    /// Timestamp for last frame (one frame before end)
    var lastFrameTimestamp: Double {
        max(0, durationInSeconds - (1.0 / frameRateDouble))
    }

    /// Duration formatted as HH:MM:SS:FF timecode
    var formattedDuration: String {
        guard let frames = Int(duration),
              let fps = Double(frameRate), fps > 0 else {
            return duration
        }
        let tc = Timecode.from(frames: frames, frameRate: fps)
        return tc.description
    }
}

/// Represents a parsing error for a single clip XML file
struct ClipParseError: Identifiable, Codable {
    let id: UUID
    private let filePathString: String
    let errorMessage: String

    var filePath: URL { URL(fileURLWithPath: filePathString) }
    var fileName: String { filePath.lastPathComponent }

    init(file: URL, error: Error) {
        self.id = UUID()
        self.filePathString = file.path
        self.errorMessage = error.localizedDescription
    }

    // For Codable
    init(file: URL, message: String) {
        self.id = UUID()
        self.filePathString = file.path
        self.errorMessage = message
    }
}

/// Represents a complete P2 card with all its clips
struct P2Card: Identifiable, Codable {
    let id: UUID
    private let rootPathString: String
    let clips: [P2Clip]
    let parseErrors: [ClipParseError]

    // URL accessor
    var rootPath: URL { URL(fileURLWithPath: rootPathString) }

    var name: String {
        rootPath.lastPathComponent
    }

    var clipCount: Int {
        clips.count
    }

    /// Whether any clips failed to parse
    var hasParseErrors: Bool {
        !parseErrors.isEmpty
    }

    /// Total duration of all clips in frames
    var totalDurationFrames: Int {
        clips.reduce(0) { $0 + $1.durationFrames }
    }

    /// Human-readable total duration
    var formattedDuration: String {
        guard let fps = clips.first?.frameRateDouble, fps > 0 else { return "--:--:--" }
        let tc = Timecode.from(frames: totalDurationFrames, frameRate: fps)
        return tc.description
    }

    init(rootPath: URL, clips: [P2Clip], parseErrors: [ClipParseError] = []) {
        self.id = UUID()
        self.rootPathString = rootPath.path
        self.clips = clips
        self.parseErrors = parseErrors
    }

    // Codable
    enum CodingKeys: String, CodingKey {
        case id, rootPathString, clips, parseErrors
    }
}

/// A group of timecode-continuous clips representing a single recording session
struct RecordGroup: Identifiable {
    let id = UUID()
    let clips: [P2Clip]
    let groupIndex: Int  // 1-based for display

    /// Start timecode of the first clip in the group
    var startTimecode: String {
        clips.first?.startTimecode ?? ""
    }

    /// Total duration in frames across all clips
    var totalDurationFrames: Int {
        clips.reduce(0) { $0 + $1.durationFrames }
    }

    /// Duration formatted as HH:MM:SS:FF timecode
    var formattedDuration: String {
        guard let fps = clips.first?.frameRateDouble, fps > 0 else { return "--:--:--:--" }
        let tc = Timecode.from(frames: totalDurationFrames, frameRate: fps)
        return tc.description
    }

    /// Number of clips in this group
    var clipCount: Int {
        clips.count
    }
}

/// Conversion settings for the MXF output
struct ConversionSettings: Codable {
    private var outputDirectoryPath: String?
    var outputFilename: String = ""
    var useFolderNameAsFilename: Bool = false
    var outputContainer: OutputContainer = .mxf
    var processingMode: ProcessingMode = .concatenate
    var preserveTimecode: Bool = true
    var audioMapping: AudioMapping = .allChannels

    // URL accessor (not encoded directly)
    var outputDirectory: URL? {
        get { outputDirectoryPath.map { URL(fileURLWithPath: $0) } }
        set { outputDirectoryPath = newValue?.path }
    }

    enum OutputContainer: String, CaseIterable, Codable {
        case mxf = "MXF"
        case mov = "MOV"

        var fileExtension: String { rawValue.lowercased() }
    }

    enum ProcessingMode: String, CaseIterable, Codable {
        case individual = "Individual Files"
        case concatenate = "Merge & Concatenate"
    }

    enum AudioMapping: String, CaseIterable, Codable {
        case allChannels = "All Channels"
        case stereoMix = "Stereo Mix (Ch 1-2)"
        case mono = "Mono (Ch 1)"
    }

    // Custom coding keys to exclude the computed outputDirectory
    enum CodingKeys: String, CodingKey {
        case outputDirectoryPath
        case outputFilename
        case useFolderNameAsFilename
        case outputContainer
        case processingMode
        case preserveTimecode
        case audioMapping
    }
}

/// Helper struct for timecode arithmetic
struct Timecode: Equatable {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let frameRate: Double

    /// Parse timecode string in format "HH:MM:SS:FF"
    init?(string: String, frameRate: Double) {
        let components = string.split(separator: ":").compactMap { Int($0) }
        guard components.count == 4 else { return nil }

        self.hours = components[0]
        self.minutes = components[1]
        self.seconds = components[2]
        self.frames = components[3]
        self.frameRate = frameRate
    }

    init(hours: Int, minutes: Int, seconds: Int, frames: Int, frameRate: Double) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.frameRate = frameRate
    }

    /// Convert to absolute frame number
    var totalFrames: Int {
        let fps = Int(frameRate)
        return hours * 3600 * fps + minutes * 60 * fps + seconds * fps + frames
    }

    /// Create timecode from total frames
    static func from(frames: Int, frameRate: Double) -> Timecode {
        let fps = Int(frameRate)
        var remaining = frames

        let h = remaining / (3600 * fps)
        remaining %= (3600 * fps)

        let m = remaining / (60 * fps)
        remaining %= (60 * fps)

        let s = remaining / fps
        let f = remaining % fps

        return Timecode(hours: h, minutes: m, seconds: s, frames: f, frameRate: frameRate)
    }

    /// Calculate frame gap between end of clip1 and start of clip2
    /// Returns: 0 = continuous, positive = gap, negative = overlap
    static func frameGap(from tc1: Timecode, duration1Frames: Int, to tc2: Timecode) -> Int {
        let expectedNextFrame = tc1.totalFrames + duration1Frames
        let actualNextFrame = tc2.totalFrames
        return actualNextFrame - expectedNextFrame
    }

    var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}

// MARK: - Progress Tracking

/// Metrics for tracking conversion progress with detailed statistics
struct ProgressMetrics {
    /// Overall progress from 0.0 to 1.0
    var progress: Double = 0.0

    /// Current phase description (e.g., "Rewrapping clip 3/10...")
    var phase: String = ""

    /// Current clip index being processed (1-based for display)
    var currentClipIndex: Int = 0

    /// Total number of clips to process
    var totalClips: Int = 0

    /// When the conversion started
    var startTime: Date?

    /// Elapsed time in seconds since start
    var elapsedSeconds: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    /// Estimated time remaining in seconds (based on current progress)
    var estimatedRemainingSeconds: TimeInterval? {
        guard progress > 0.05 else { return nil }  // Need at least 5% to estimate
        let elapsed = elapsedSeconds
        guard elapsed > 0 else { return nil }
        let totalEstimated = elapsed / progress
        return max(0, totalEstimated - elapsed)
    }

    /// FFmpeg-reported speed (e.g., "12.5x")
    var speed: String?

    /// FFmpeg-reported fps
    var fps: Double?

    /// FFmpeg-reported processed time (e.g., "00:01:23.45")
    var processedTime: String?

    /// FFmpeg-reported current frame number
    var currentFrame: Int?

    /// Total expected frames (if known)
    var totalFrames: Int?

    /// Format elapsed time as MM:SS or HH:MM:SS
    var formattedElapsed: String {
        formatTimeInterval(elapsedSeconds)
    }

    /// Format estimated remaining as MM:SS or HH:MM:SS
    var formattedRemaining: String? {
        guard let remaining = estimatedRemainingSeconds else { return nil }
        return formatTimeInterval(remaining)
    }

    /// Format speed and fps for display
    var formattedSpeed: String? {
        if let speed = speed {
            return speed
        } else if let fps = fps {
            return String(format: "%.1f fps", fps)
        }
        return nil
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

/// Status of a clip during conversion
enum ConversionStatus: Equatable {
    case pending
    case inProgress(progress: Double)
    case finalizing  // File move/cleanup phase after processing
    case completed
    case failed(error: String)

    var description: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress(let progress): return "Merging \(Int(progress * 100))%"
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - Verification Models

/// Verification mode options
enum VerificationMode: String, CaseIterable, Codable {
    case quick = "Quick"
    case full = "Full"

    var description: String {
        switch self {
        case .quick: return "Container + first/last 5 seconds"
        case .full: return "Decode every frame"
        }
    }
}

/// Status of file verification
enum VerificationStatus: Equatable, Codable {
    case unverified       // Not yet verified
    case verifying        // Currently running verification
    case verified         // Passed verification
    case failed(String)   // Failed with error message

    var displayName: String {
        switch self {
        case .unverified: return "Not Verified"
        case .verifying: return "Verifying..."
        case .verified: return "Verified"
        case .failed: return "Failed"
        }
    }

    var iconName: String {
        switch self {
        case .unverified: return "questionmark.circle"
        case .verifying: return "arrow.triangle.2.circlepath"
        case .verified: return "checkmark.seal.fill"
        case .failed: return "xmark.seal.fill"
        }
    }

    var isFinished: Bool {
        switch self {
        case .verified, .failed: return true
        default: return false
        }
    }

    // MARK: - Codable (custom for associated value)

    private enum CodingKeys: String, CodingKey {
        case type, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "unverified": self = .unverified
        case "verifying": self = .verifying
        case "verified": self = .verified
        case "failed":
            let message = try container.decode(String.self, forKey: .errorMessage)
            self = .failed(message)
        default: self = .unverified
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .unverified: try container.encode("unverified", forKey: .type)
        case .verifying: try container.encode("verifying", forKey: .type)
        case .verified: try container.encode("verified", forKey: .type)
        case .failed(let message):
            try container.encode("failed", forKey: .type)
            try container.encode(message, forKey: .errorMessage)
        }
    }
}

/// Detailed results from verification
struct VerificationResult: Codable {
    let fileURL: URL
    let passed: Bool
    let mode: VerificationMode
    let duration: TimeInterval         // How long verification took
    let framesDecoded: Int?            // Number of frames successfully decoded
    let totalFrames: Int?              // Expected total frames
    let decodingSpeed: String?         // e.g., "45.2x"
    let containerValid: Bool           // MXF/MOV structure is valid
    let errorMessage: String?          // If failed, what went wrong
    let verifiedAt: Date

    var summary: String {
        if passed {
            var parts = ["✓ Verified"]
            if let frames = framesDecoded {
                parts.append("\(frames) frames")
            }
            if let speed = decodingSpeed {
                parts.append(speed)
            }
            parts.append(String(format: "%.1fs", duration))
            return parts.joined(separator: " • ")
        } else {
            return "✗ Failed: \(errorMessage ?? "Unknown error")"
        }
    }
}

// MARK: - Time Estimation Models

/// Estimated time for a conversion job
struct ConversionEstimate {
    let totalBytes: Int64
    let totalDurationSeconds: Double
    let clipCount: Int
    let estimatedSeconds: TimeInterval
    let speedMultiplier: Double       // e.g., 30.0 means 30x realtime
    let confidence: EstimateConfidence

    /// Formatted total size (e.g., "42.3 GB")
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Formatted duration of source content (e.g., "1:23:45")
    var formattedSourceDuration: String {
        formatTimeInterval(totalDurationSeconds)
    }

    /// Formatted estimated time (e.g., "~3 min")
    var formattedEstimate: String {
        if estimatedSeconds < 60 {
            return "< 1 min"
        } else if estimatedSeconds < 3600 {
            let mins = Int(estimatedSeconds / 60)
            return "~\(mins) min"
        } else {
            let hours = Int(estimatedSeconds / 3600)
            let mins = Int((estimatedSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "~\(hours)h \(mins)m"
        }
    }

    /// Formatted speed (e.g., "30x realtime")
    var formattedSpeed: String {
        String(format: "%.0fx realtime", speedMultiplier)
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

/// Confidence level in the time estimate
enum EstimateConfidence: String {
    case high = "Based on recent conversions"
    case medium = "Based on historical average"
    case low = "Using default estimate"

    var icon: String {
        switch self {
        case .high: return "checkmark.circle.fill"
        case .medium: return "circle.fill"
        case .low: return "questionmark.circle"
        }
    }
}

/// Record of a completed conversion for speed tracking
struct ConversionSpeedRecord: Codable {
    let date: Date
    let bytesProcessed: Int64
    let durationSeconds: TimeInterval
    let speedMultiplier: Double        // Realtime multiplier (e.g., 30.0 for 30x)
    let processingMode: ConversionSettings.ProcessingMode
    let outputFormat: ConversionSettings.OutputContainer

    /// Throughput in bytes per second
    var bytesPerSecond: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(bytesProcessed) / durationSeconds
    }
}

/// Slow speed warning threshold and data
struct SlowSpeedWarning {
    let currentSpeed: Double          // Current realtime multiplier
    let expectedSpeed: Double         // Expected based on history
    let estimatedRemaining: TimeInterval
    let reason: SlowSpeedReason

    var message: String {
        switch reason {
        case .slowDisk:
            return "Slow disk speed detected"
        case .externalDrive:
            return "External drive may be slow"
        case .networkStorage:
            return "Network storage latency"
        case .systemLoad:
            return "High system activity"
        case .unknown:
            return "Slower than expected"
        }
    }

    var formattedRemaining: String {
        if estimatedRemaining < 60 {
            return "< 1 min remaining"
        } else if estimatedRemaining < 3600 {
            let mins = Int(estimatedRemaining / 60)
            return "~\(mins) min remaining"
        } else {
            let hours = Int(estimatedRemaining / 3600)
            let mins = Int((estimatedRemaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return "~\(hours)h \(mins)m remaining"
        }
    }
}

enum SlowSpeedReason {
    case slowDisk
    case externalDrive
    case networkStorage
    case systemLoad
    case unknown
}

// MARK: - Batch Queue Models

/// Status of a conversion job in the queue
enum JobStatus: Equatable, Codable {
    case pending       // Waiting in queue
    case preparing     // Gathering files/rewrapping
    case active        // FFmpeg is processing
    case completed     // Successfully finished
    case failed(String) // Error encountered
    case cancelled     // User cancelled

    var displayName: String {
        switch self {
        case .pending: return "Queued"
        case .preparing: return "Preparing"
        case .active: return "Converting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .preparing: return "gearshape.2"
        case .active: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - Codable (custom for associated value)

    private enum CodingKeys: String, CodingKey {
        case type, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pending": self = .pending
        case "preparing": self = .preparing
        case "active": self = .active
        case "completed": self = .completed
        case "failed":
            let message = try container.decode(String.self, forKey: .errorMessage)
            self = .failed(message)
        case "cancelled": self = .cancelled
        default: self = .pending
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pending: try container.encode("pending", forKey: .type)
        case .preparing: try container.encode("preparing", forKey: .type)
        case .active: try container.encode("active", forKey: .type)
        case .completed: try container.encode("completed", forKey: .type)
        case .failed(let message):
            try container.encode("failed", forKey: .type)
            try container.encode(message, forKey: .errorMessage)
        case .cancelled: try container.encode("cancelled", forKey: .type)
        }
    }
}

/// A single conversion job in the queue
struct ConversionJob: Identifiable, Codable {
    let id: UUID
    let cardName: String          // Source P2 card name
    private var cardPathString: String  // For security-scoped access (stored as path)
    let clips: [P2Clip]           // Clips to process
    let settings: ConversionSettings
    private var destinationPathString: String  // Final output path (stored as path)
    let createdAt: Date

    var status: JobStatus = .pending
    var progress: Double = 0.0    // 0.0 to 1.0
    var startedAt: Date?          // When processing started (for elapsed time)

    // Security-scoped bookmark data for persisting file access across app launches
    var cardBookmarkData: Data?
    var outputBookmarkData: Data?

    // Verification state
    var verificationStatus: VerificationStatus = .unverified
    var verificationResult: VerificationResult?
    var verificationProgress: Double = 0.0  // 0.0 to 1.0

    // URL accessors
    var cardPath: URL {
        get { URL(fileURLWithPath: cardPathString) }
        set { cardPathString = newValue.path }
    }
    var destinationURL: URL {
        get { URL(fileURLWithPath: destinationPathString) }
        set { destinationPathString = newValue.path }
    }

    /// Resolves the card bookmark to a security-scoped URL
    /// - Returns: URL with security scope, or nil if bookmark is invalid/stale
    mutating func resolveCardBookmark() -> URL? {
        guard let data = cardBookmarkData else {
            return URL(fileURLWithPath: cardPathString)
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            // Try to regenerate bookmark with new URL
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                cardBookmarkData = newData
            }
        }
        cardPathString = url.path
        return url
    }

    /// Resolves the output bookmark to a security-scoped URL
    /// - Returns: URL with security scope, or nil if bookmark is invalid/stale
    mutating func resolveOutputBookmark() -> URL? {
        guard let data = outputBookmarkData else {
            return URL(fileURLWithPath: destinationPathString)
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            // Try to regenerate bookmark with new URL
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                outputBookmarkData = newData
            }
        }
        destinationPathString = url.path
        return url
    }

    /// Display name for the job (uses output filename or card name)
    var displayName: String {
        if settings.processingMode == .individual {
            return "\(cardName) (\(clips.count) clips)"
        } else {
            return destinationURL.deletingPathExtension().lastPathComponent
        }
    }

    /// Expected output format
    var outputFormat: String {
        settings.outputContainer.rawValue
    }

    /// Total duration of all clips in frames
    var totalDurationFrames: Int {
        clips.reduce(0) { $0 + $1.durationFrames }
    }

    /// Human-readable duration
    var formattedDuration: String {
        guard let fps = clips.first?.frameRateDouble, fps > 0 else { return "--:--:--" }
        let tc = Timecode.from(frames: totalDurationFrames, frameRate: fps)
        return tc.description
    }

    init(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL,
        cardBookmarkData: Data? = nil,
        outputBookmarkData: Data? = nil
    ) {
        self.id = UUID()
        self.cardName = cardName
        self.cardPathString = cardPath.path
        self.clips = clips
        self.settings = settings
        self.destinationPathString = destinationURL.path
        self.createdAt = Date()
        self.cardBookmarkData = cardBookmarkData
        self.outputBookmarkData = outputBookmarkData
    }

    /// Creates a job with security-scoped bookmarks from the provided URLs
    /// - Note: Call this when the URLs have active security scope (e.g., from NSOpenPanel)
    static func withBookmarks(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL
    ) -> ConversionJob {
        // Create security-scoped bookmarks while we have access
        let cardBookmark = try? cardPath.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let outputBookmark = try? destinationURL.deletingLastPathComponent().bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return ConversionJob(
            cardName: cardName,
            cardPath: cardPath,
            clips: clips,
            settings: settings,
            destinationURL: destinationURL,
            cardBookmarkData: cardBookmark,
            outputBookmarkData: outputBookmark
        )
    }

    // Codable keys
    enum CodingKeys: String, CodingKey {
        case id, cardName, cardPathString, clips, settings
        case destinationPathString, createdAt, status, progress, startedAt
        case cardBookmarkData, outputBookmarkData
        case verificationStatus, verificationResult, verificationProgress
    }
}
