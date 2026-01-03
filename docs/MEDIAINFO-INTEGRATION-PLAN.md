# MediaInfo Integration Plan for P2toMXF

## Summary of Findings

**What is MediaInfo?**
- Specialized media analysis tool from MediaArea (same team behind MediaConch)
- BSD-2-Clause license (compatible with app distribution)
- Better MXF/broadcast metadata extraction than FFprobe
- Supports JSON, XML, EBUCore output formats

**Binary Footprint:**

| Component | Size |
|-----------|------|
| `mediainfo` binary | 127 KB |
| `libmediainfo.dylib` | 7.7 MB |
| `libzen.dylib` | 283 KB |
| **Total** | **~8.1 MB** |

Compare to: FFmpeg (59 MB), BMX stack (~4 MB)

## What MediaInfo Adds Over FFprobe

| Feature | FFprobe | MediaInfo |
|---------|---------|-----------|
| Timecode extraction | Basic | Better (multiple TC tracks) |
| Codec profile display | Technical IDs | Human-readable ("AVC-Intra 100") |
| MXF OP detection | Limited | Full (OP-Atom, OP1a, etc.) |
| Custom output templates | Limited | Extensive (`--Output=` templates) |
| EBUCore metadata export | No | Native support |
| JSON structure | Flat | Hierarchical by stream type |

## Proposed Integration

### Phase 1: Enhanced Clip Display

```swift
// Use MediaInfo for richer clip metadata in the UI
struct MediaInfoParser {
    func analyze(_ url: URL) async throws -> ClipMetadata
}

struct ClipMetadata {
    let codecProfile: String      // "AVC-Intra 100" vs "avc1"
    let timecodeStart: String     // Better TC parsing
    let operationalPattern: String // "OP-Atom", "OP1a"
    let colorSpace: String        // "BT.709"
    let bitDepth: Int
}
```

### Phase 2: Console Output Enhancement

- Show MediaInfo summary when loading P2 card
- Display codec profile in human-readable format
- Show MXF operational pattern

### Phase 3: Export Metadata Report

- Option to export EBUCore XML alongside converted files
- Useful for archive/compliance workflows

## CLI Usage Examples

```bash
# JSON output (best for parsing)
mediainfo --Output=JSON input.mxf

# Specific fields only
mediainfo --Output="Video;%Format% %Format_Profile%\n" input.mxf
# Output: "AVC AVC-Intra 100"

# Timecode
mediainfo --Output="Other;%TimeCode_FirstFrame%\n" input.mxf
# Output: "18:09:34:24"

# Full broadcast-relevant template
mediainfo --Output="General;Container: %Format%\nOP: %Format_Profile%\n" \
          --Output="Video;Codec: %Format% %Format_Profile%\nRes: %Width%x%Height%\nTC: %TimeCode_FirstFrame%\n" \
          input.mxf
```

## Bundling Strategy

Same pattern as BMX - copy binaries + fix dylib paths:

```
Resources/
├── ffmpeg                    (59 MB)
├── bmxtranswrap              (268 KB)
├── mxf2raw                   (252 KB)
├── mediainfo                 (127 KB)  # NEW
├── lib/
│   ├── libbmx.1.dylib        (2.2 MB)
│   ├── libMXF++.1.dylib      (634 KB)
│   ├── libMXF.1.dylib        (805 KB)
│   ├── libexpat.1.dylib      (163 KB)
│   ├── liburiparser.1.dylib  (145 KB)
│   ├── libmediainfo.0.dylib  (7.7 MB)  # NEW
│   └── libzen.0.dylib        (283 KB)  # NEW
```

### Fix Library Paths

```bash
# Fix mediainfo to use bundled libraries
install_name_tool -change /opt/homebrew/opt/libmediainfo/lib/libmediainfo.0.dylib \
  @executable_path/lib/libmediainfo.0.dylib mediainfo

install_name_tool -change /opt/homebrew/opt/libzen/lib/libzen.0.dylib \
  @executable_path/lib/libzen.0.dylib mediainfo

# Fix libmediainfo to find libzen
install_name_tool -change /opt/homebrew/opt/libzen/lib/libzen.0.dylib \
  @executable_path/lib/libzen.0.dylib lib/libmediainfo.0.dylib

# Sign after modification
codesign --force --sign - mediainfo lib/libmediainfo.0.dylib lib/libzen.0.dylib
```

## Swift Integration

### MediaInfoWrapper Service

```swift
import Foundation

actor MediaInfoWrapper {
    private let mediaInfoPath: URL

    init() {
        mediaInfoPath = Bundle.main.url(forResource: "mediainfo", withExtension: nil)!
    }

    func analyze(_ fileURL: URL) async throws -> MediaInfoResult {
        let process = Process()
        process.executableURL = mediaInfoPath
        process.arguments = ["--Output=JSON", fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode(MediaInfoResult.self, from: data)
    }

    func getTimecode(_ fileURL: URL) async throws -> String? {
        let process = Process()
        process.executableURL = mediaInfoPath
        process.arguments = ["--Output=Other;%TimeCode_FirstFrame%", fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func getCodecProfile(_ fileURL: URL) async throws -> String? {
        let process = Process()
        process.executableURL = mediaInfoPath
        process.arguments = ["--Output=Video;%Format% %Format_Profile%", fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### JSON Response Structure

```swift
struct MediaInfoResult: Codable {
    let media: Media

    struct Media: Codable {
        let track: [Track]

        enum CodingKeys: String, CodingKey {
            case track = "@track"
        }
    }

    struct Track: Codable {
        let type: String
        let format: String?
        let formatProfile: String?
        let codecID: String?
        let duration: String?
        let width: String?
        let height: String?
        let frameRate: String?
        let bitDepth: String?
        let colorSpace: String?
        let timeCodeFirstFrame: String?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case format = "Format"
            case formatProfile = "Format_Profile"
            case codecID = "CodecID"
            case duration = "Duration"
            case width = "Width"
            case height = "Height"
            case frameRate = "FrameRate"
            case bitDepth = "BitDepth"
            case colorSpace = "ColorSpace"
            case timeCodeFirstFrame = "TimeCode_FirstFrame"
        }
    }
}
```

## Decision Point

**Add MediaInfo?**

| Pro | Con |
|-----|-----|
| Better metadata display | Another binary to bundle/sign |
| Only 8 MB footprint | FFprobe already works for basic needs |
| Broadcast-standard output formats | Additional maintenance |
| Human-readable codec profiles | |

**Recommendation:** Worth adding for the improved codec profile display and timecode handling. The 8 MB footprint is modest compared to FFmpeg's 59 MB.

## Implementation Checklist

- [ ] Download/build MediaInfo CLI for arm64
- [ ] Copy mediainfo + libmediainfo + libzen to Resources/
- [ ] Fix dylib paths with install_name_tool
- [ ] Update sign-bundled-binaries.sh
- [ ] Create MediaInfoWrapper.swift service
- [ ] Update P2CardParser to use MediaInfo for enhanced metadata
- [ ] Update clip list UI to show codec profile
- [ ] Test with various P2 card formats
