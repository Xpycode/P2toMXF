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

    // Spanned clip metadata (from <Relation> element)
    let globalShotID: String?          // Shared ID across spanned clips
    let spanPreviousClipID: String?    // GlobalClipID of previous span
    let spanNextClipID: String?        // GlobalClipID of next span
    let spanTopClipID: String?         // GlobalClipID of first clip in span

    // File paths (stored as strings for Codable, converted to URLs via computed properties)
    private let videoFilePaths: [String]
    private let audioFilePaths: [String]
    private let metadataFilePath: String
    private let proxyFilePath: String?
    private let iconFilePath: String?

    // MARK: - URL Accessors

    /// Video MXF file URLs (typically 1 file for P2)
    var videoFiles: [URL] { videoFilePaths.map { URL(fileURLWithPath: $0) } }
    /// Audio MXF file URLs (typically 4 mono channels for P2)
    var audioFiles: [URL] { audioFilePaths.map { URL(fileURLWithPath: $0) } }
    /// XML metadata file URL
    var metadataFile: URL { URL(fileURLWithPath: metadataFilePath) }
    /// Low-resolution proxy file URL, if available
    var proxyFile: URL? { proxyFilePath.map { URL(fileURLWithPath: $0) } }
    /// Thumbnail icon file URL, if available
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
        iconFile: URL?,
        globalShotID: String? = nil,
        spanPreviousClipID: String? = nil,
        spanNextClipID: String? = nil,
        spanTopClipID: String? = nil
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
        self.globalShotID = globalShotID
        self.spanPreviousClipID = spanPreviousClipID
        self.spanNextClipID = spanNextClipID
        self.spanTopClipID = spanTopClipID
    }

    /// User-friendly name for display, preferring clipName over globalClipID
    var displayName: String {
        clipName.isEmpty ? globalClipID : clipName
    }

    // MARK: - Span Detection

    /// True if this clip is part of a spanned recording (camera-split)
    var isSpanned: Bool {
        globalShotID != nil && (spanPreviousClipID != nil || spanNextClipID != nil)
    }

    /// True if this is the first clip in a spanned sequence
    var isSpanStart: Bool {
        isSpanned && spanPreviousClipID == nil
    }

    /// True if this is the last clip in a spanned sequence
    var isSpanEnd: Bool {
        isSpanned && spanNextClipID == nil
    }

    /// True if this is a middle clip in a spanned sequence
    var isSpanMiddle: Bool {
        isSpanned && spanPreviousClipID != nil && spanNextClipID != nil
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

    /// Full URL to the XML file that failed to parse
    var filePath: URL { URL(fileURLWithPath: filePathString) }
    /// Just the filename component for display
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

    /// URL to the P2 card root directory (CONTENTS folder parent)
    var rootPath: URL { URL(fileURLWithPath: rootPathString) }

    /// Card name derived from folder name (e.g., "P2 Card 001")
    var name: String {
        rootPath.lastPathComponent
    }

    /// Number of successfully parsed clips on this card
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

/// A group of clips representing a single recording session
struct RecordGroup: Identifiable {
    // Derive ID from first clip for stable identity across recomputes
    // This prevents SwiftUI from treating groups as new items on every access
    var id: UUID { clips.first?.id ?? UUID() }
    let clips: [P2Clip]
    let groupIndex: Int  // 1-based for display
    let groupType: GroupType

    /// How this group was detected
    enum GroupType {
        case spanned        // Clips share GlobalShotID (camera-split recording)
        case continuous     // Timecode-continuous but not spanned
        case single         // Single clip, no grouping needed
    }

    init(clips: [P2Clip], groupIndex: Int, groupType: GroupType = .continuous) {
        self.clips = clips
        self.groupIndex = groupIndex
        self.groupType = groupType
    }

    /// True if this group was detected via span metadata
    var isSpanned: Bool {
        groupType == .spanned
    }

    /// Start timecode of the first clip in the group (for display and continuity checking)
    var startTimecode: String {
        clips.first?.startTimecode ?? ""
    }

    /// Total duration in frames across all clips in this recording group
    var totalDurationFrames: Int {
        clips.reduce(0) { $0 + $1.durationFrames }
    }

    /// Duration formatted as HH:MM:SS:FF timecode for display
    var formattedDuration: String {
        guard let fps = clips.first?.frameRateDouble, fps > 0 else { return "--:--:--:--" }
        let tc = Timecode.from(frames: totalDurationFrames, frameRate: fps)
        return tc.description
    }

    /// Number of clips in this recording group
    var clipCount: Int {
        clips.count
    }

    /// Description of how the group was formed
    var groupTypeLabel: String {
        switch groupType {
        case .spanned: return "Spanned"
        case .continuous: return "Continuous"
        case .single: return "Single"
        }
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
    var generateReport: Bool = true
    var includeChecksum: Bool = false

    /// Output directory URL for converted files (not encoded directly, derived from path)
    var outputDirectory: URL? {
        get { outputDirectoryPath.map { URL(fileURLWithPath: $0) } }
        set { outputDirectoryPath = newValue?.path }
    }

    enum OutputContainer: String, CaseIterable, Codable {
        case mxf = "MXF"
        case mov = "MOV"

        /// Lowercase file extension for use in filenames
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
        case generateReport
        case includeChecksum
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

    /// Convert to absolute frame number for arithmetic operations
    /// Note: Uses rounded frame rate to handle NTSC (29.97 → 30, 23.976 → 24)
    var totalFrames: Int {
        let fps = Int(frameRate.rounded())
        return hours * 3600 * fps + minutes * 60 * fps + seconds * fps + frames
    }

    /// Create timecode from total frames
    /// Note: Uses rounded frame rate to handle NTSC (29.97 → 30, 23.976 → 24)
    static func from(frames: Int, frameRate: Double) -> Timecode {
        let fps = Int(frameRate.rounded())
        guard fps > 0 else {
            return Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: frameRate)
        }
        var remaining = frames

        let h = remaining / (3600 * fps)
        remaining %= (3600 * fps)

        let m = remaining / (60 * fps)
        remaining %= (60 * fps)

        let s = remaining / fps
        let f = remaining % fps

        return Timecode(hours: h, minutes: m, seconds: s, frames: f, frameRate: frameRate)
    }

    /// Calculates the frame gap between end of clip1 and start of clip2
    /// Returns: 0 = continuous, positive = gap, negative = overlap
    static func frameGap(from tc1: Timecode, duration1Frames: Int, to tc2: Timecode) -> Int {
        let expectedNextFrame = tc1.totalFrames + duration1Frames
        let actualNextFrame = tc2.totalFrames
        return actualNextFrame - expectedNextFrame
    }

    /// Formatted timecode string (HH:MM:SS:FF) for display
    var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}

