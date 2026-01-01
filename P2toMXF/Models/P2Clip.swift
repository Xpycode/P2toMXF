import Foundation

/// Represents a single P2 clip with its associated video, audio, and metadata
struct P2Clip: Identifiable, Hashable {
    let id = UUID()
    let clipName: String
    let globalClipID: String
    let duration: String
    let startTimecode: String
    let frameRate: String
    let videoCodec: String
    let audioChannels: Int

    // File paths
    let videoFiles: [URL]
    let audioFiles: [URL]
    let metadataFile: URL

    var displayName: String {
        clipName.isEmpty ? globalClipID : clipName
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

/// Represents a complete P2 card with all its clips
struct P2Card: Identifiable {
    let id = UUID()
    let rootPath: URL
    let clips: [P2Clip]

    var name: String {
        rootPath.lastPathComponent
    }

    var clipCount: Int {
        clips.count
    }
}

/// Conversion settings for the MXF output
struct ConversionSettings {
    var outputDirectory: URL?
    var outputFilename: String = ""
    var outputContainer: OutputContainer = .mov
    var processingMode: ProcessingMode = .concatenate
    var preserveTimecode: Bool = true
    var audioMapping: AudioMapping = .allChannels

    enum OutputContainer: String, CaseIterable {
        case mov = "MOV"
        case mxf = "MXF"

        var fileExtension: String { rawValue.lowercased() }
    }

    enum ProcessingMode: String, CaseIterable {
        case individual = "Individual Files"
        case concatenate = "Merge & Concatenate"
    }

    enum AudioMapping: String, CaseIterable {
        case allChannels = "All Channels"
        case stereoMix = "Stereo Mix (Ch 1-2)"
        case mono = "Mono (Ch 1)"
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

/// Status of a clip during conversion
enum ConversionStatus: Equatable {
    case pending
    case inProgress(progress: Double)
    case completed
    case failed(error: String)

    var description: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress(let progress): return "Merging \(Int(progress * 100))%"
        case .completed: return "Completed"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}
