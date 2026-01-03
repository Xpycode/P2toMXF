import Foundation

/// Parses P2 card folder structures and extracts clip metadata from XML files
class P2CardParser {

    enum ParserError: LocalizedError {
        case invalidP2Structure(String)
        case xmlParsingFailed(String)
        case missingRequiredField(String)

        var errorDescription: String? {
            switch self {
            case .invalidP2Structure(let msg): return "Invalid P2 structure: \(msg)"
            case .xmlParsingFailed(let msg): return "XML parsing failed: \(msg)"
            case .missingRequiredField(let field): return "Missing required field: \(field)"
            }
        }
    }

    /// Validates that the given URL points to a valid P2 card structure
    func validateP2Structure(at url: URL) -> Bool {
        let fm = FileManager.default
        let contentsPath = url.appendingPathComponent("CONTENTS")

        // Check for required P2 directories
        let requiredDirs = ["CLIP", "VIDEO"]
        for dir in requiredDirs {
            let dirPath = contentsPath.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dirPath.path, isDirectory: &isDir) || !isDir.boolValue {
                return false
            }
        }
        return true
    }

    /// Parses a P2 card and returns all clips found
    func parseP2Card(at url: URL) throws -> P2Card {
        guard validateP2Structure(at: url) else {
            throw ParserError.invalidP2Structure("Missing CONTENTS/CLIP or CONTENTS/VIDEO directories")
        }

        let contentsPath = url.appendingPathComponent("CONTENTS")
        let clipPath = contentsPath.appendingPathComponent("CLIP")

        // Find all XML files in CLIP directory
        let fm = FileManager.default
        let xmlFiles = try fm.contentsOfDirectory(at: clipPath, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "XML" }

        var clips: [P2Clip] = []
        var parseErrors: [ClipParseError] = []

        for xmlFile in xmlFiles {
            do {
                let clip = try parseClipXML(at: xmlFile, contentsPath: contentsPath)
                clips.append(clip)
            } catch {
                parseErrors.append(ClipParseError(file: xmlFile, error: error))
                print("[P2CardParser] Failed to parse \(xmlFile.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Sort by timecode
        clips.sort { $0.startTimecode < $1.startTimecode }

        return P2Card(rootPath: url, clips: clips, parseErrors: parseErrors)
    }

    /// Parses a single clip XML file and extracts metadata
    private func parseClipXML(at url: URL, contentsPath: URL) throws -> P2Clip {
        let data = try Data(contentsOf: url)
        let parser = P2XMLParser(data: data)
        let metadata = try parser.parse()

        let fm = FileManager.default

        // Build file paths based on P2 naming convention
        let videoPath = contentsPath.appendingPathComponent("VIDEO")
        let audioPath = contentsPath.appendingPathComponent("AUDIO")
        let proxyPath = contentsPath.appendingPathComponent("PROXY")
        let iconPath = contentsPath.appendingPathComponent("ICON")

        var videoFiles: [URL] = []
        var audioFiles: [URL] = []

        // P2 video file: {ClipName}.MXF
        let videoFile = videoPath.appendingPathComponent("\(metadata.clipName).MXF")
        if fm.fileExists(atPath: videoFile.path) {
            videoFiles.append(videoFile)
        }

        // P2 audio files: {ClipName}00.MXF, {ClipName}01.MXF, etc.
        for i in 0..<metadata.audioChannels {
            let audioFileName = String(format: "%@%02d.MXF", metadata.clipName, i)
            let audioFile = audioPath.appendingPathComponent(audioFileName)
            if fm.fileExists(atPath: audioFile.path) {
                audioFiles.append(audioFile)
            }
        }

        // Thumbnail sources (optional - may not exist on all P2 cards)
        // PROXY/{ClipName}.MP4 - low-res proxy video for fast thumbnail extraction
        let proxyFile = proxyPath.appendingPathComponent("\(metadata.clipName).MP4")
        let proxyURL: URL? = fm.fileExists(atPath: proxyFile.path) ? proxyFile : nil

        // ICON/{ClipName}.BMP - single frame thumbnail (first frame only)
        let iconFile = iconPath.appendingPathComponent("\(metadata.clipName).BMP")
        let iconURL: URL? = fm.fileExists(atPath: iconFile.path) ? iconFile : nil

        return P2Clip(
            clipName: metadata.clipName,
            globalClipID: metadata.globalClipID,
            duration: String(metadata.durationInTCFrames),  // Convert edit units to TC frames
            startTimecode: metadata.startTimecode,
            frameRate: metadata.frameRate,
            videoCodec: metadata.videoCodec,
            audioChannels: metadata.audioChannels,
            videoFiles: videoFiles,
            audioFiles: audioFiles,
            metadataFile: url,
            proxyFile: proxyURL,
            iconFile: iconURL
        )
    }
}

// MARK: - XML Parser

private struct P2ClipMetadata {
    var clipName: String = ""
    var globalClipID: String = ""
    var duration: String = ""          // Raw duration in edit units
    var editUnit: String = "1/25"      // Edit unit denominator (e.g., "1/50" means 50 units/sec)
    var startTimecode: String = ""
    var frameRate: String = "25"       // Timecode frame rate (from codec)
    var frameRateFromCodec: Bool = false  // Track if we got rate from codec
    var videoCodec: String = "AVC-Intra"
    var audioChannels: Int = 0

    /// Duration converted to timecode frames
    var durationInTCFrames: Int {
        guard let rawDuration = Int(duration) else { return 0 }

        // Parse edit unit denominator (e.g., "1/50" -> 50)
        let editRate: Int
        if let slashIndex = editUnit.firstIndex(of: "/") {
            let denomStr = editUnit[editUnit.index(after: slashIndex)...]
            editRate = Int(denomStr) ?? 25
        } else {
            editRate = 25
        }

        // Parse TC frame rate from codec (e.g., "25")
        let tcRate = Int(frameRate) ?? 25

        // Convert: duration_edit_units * (tc_rate / edit_rate)
        // Use integer math to avoid floating point issues
        return rawDuration * tcRate / editRate
    }
}

private class P2XMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var metadata = P2ClipMetadata()
    private var currentElement = ""
    private var currentText = ""
    private var inEssenceList = false
    private var inVideo = false
    private var parseError: Error?
    private var clipNameDepth = 0  // Track nesting to get the right ClipName

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> P2ClipMetadata {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        if let error = parseError {
            throw error
        }

        return metadata
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "EssenceList":
            inEssenceList = true
        case "Video":
            if inEssenceList {
                inVideo = true
            }
        case "Audio":
            if inEssenceList {
                // Count audio channels
                metadata.audioChannels += 1
            }
        case "ClipName":
            clipNameDepth += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "ClipName":
            // Only capture the first (top-level) ClipName in ClipContent
            if clipNameDepth == 1 && metadata.clipName.isEmpty {
                metadata.clipName = text
            }
            clipNameDepth -= 1
        case "GlobalClipID":
            if metadata.globalClipID.isEmpty {
                metadata.globalClipID = text
            }
        case "Duration":
            if metadata.duration.isEmpty {
                metadata.duration = text
            }
        case "EditUnit":
            if metadata.editUnit == "1/25" {
                metadata.editUnit = text
            }
        case "StartTimecode":
            // Get timecode from Video element
            if inVideo && metadata.startTimecode.isEmpty {
                metadata.startTimecode = text
            }
        case "FrameRate":
            // Only use FrameRate element as fallback if Codec didn't provide the TC rate
            if inVideo && !metadata.frameRateFromCodec {
                let numericPart = text.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                metadata.frameRate = numericPart
            }
        case "Codec":
            if inVideo {
                metadata.videoCodec = text
                // Extract timecode frame rate from codec string (e.g., "AVC-I_1080/25p" -> "25")
                // This is the actual TC rate, not the sensor rate from FrameRate element
                if let match = text.range(of: #"/(\d+)[pi]?"#, options: .regularExpression) {
                    let rateStr = text[match].dropFirst() // Remove leading "/"
                        .replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                    if !rateStr.isEmpty {
                        metadata.frameRate = rateStr
                        metadata.frameRateFromCodec = true  // Mark that we got TC rate from codec
                    }
                }
            }
        case "Video":
            inVideo = false
        case "EssenceList":
            inEssenceList = false
        default:
            break
        }

        currentElement = ""
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
