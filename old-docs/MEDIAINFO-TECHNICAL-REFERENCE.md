# MediaInfo: Deep Technical Analysis for Broadcast Workflows

## Executive Overview

**MediaInfo** is the broadcast industry's de facto standard for **metadata extraction and file analysis**. Unlike **FFmpeg** (which focuses on decoding/transcoding) or **BMX** (which focuses on strict compliance writing), MediaInfo is built purely for **inspection**. It excels at identifying "what a file is" without necessarily reading every byte of the essence.

Its architecture allows it to parse obscure legacy broadcast containers (LXF, GXF) and complex metadata hierarchies (Dolby E, SCTE-35, CEA-708) that general-purpose tools often ignore.

## 1. Core Architecture

MediaInfo is not a single executable but a layered architecture centered around **`libmediainfo`**.

### The Library (`libmediainfo`)

*   **Role:** The C++ core that performs all parsing logic.
*   **Design Philosophy:** It is a **header parser**, not a decoder. It reads file headers (moov atoms, MXF partitions, MPEG-TS PSI tables) to extract technical parameters.
*   **Stream Detection:** It uses "Sniffers" to detect stream types. If it sees a PCM audio track, it will "sniff" the first few packets to see if it's actually **Dolby E** or **AC-3** disguised as PCM—a critical feature for broadcast archives.

### Library Stack

```
┌─────────────────────────────────────────────────────┐
│              mediainfo (CLI / GUI)                  │
│                  User Interface                     │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│              libmediainfo (C++)                     │
│         Container & Codec Parsing Engine            │
│   • Header parsing (not decoding)                   │
│   • Stream "sniffing" (Dolby E, AC-3 in PCM)       │
│   • Metadata extraction                             │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                 libzen (C++)                        │
│           Core Utilities & Abstractions             │
└─────────────────────────────────────────────────────┘
```

### Interfaces

1.  **CLI (`mediainfo`):** The command-line tool for automation.
2.  **GUI:** The desktop application (View -> Tree/Text/HTML).
3.  **DLL/.so/.dylib:** Shared libraries for integration into C++, C#, VB.NET, and Python.
4.  **Mini-Wrappers:** `pymediainfo` (Python) is the standard wrapper that calls the DLL directly, returning native Python objects instead of raw text.

## 2. Parsing Modes & Performance

One of MediaInfo's most critical (and misunderstood) features is its variable parsing depth.

### `ParseSpeed` (0.0 - 1.0)

This setting controls how much of the file MediaInfo reads to determine duration and stream attributes.

| Value | Mode | Behavior | Risk |
|-------|------|----------|------|
| **0.0** | Fastest | Reads *only* the header | VBR duration may be wrong; streams not in header missed |
| **0.5** | Default | Header + jump to end | Good balance for most files |
| **1.0** | Full Parse | Reads **entire file** | Required for exact VBR frame counts; very slow on large files |

**CLI Usage:**
```bash
# Fast header-only parse
mediainfo --ParseSpeed=0 input.mxf

# Full file parse (slow but accurate)
mediainfo --ParseSpeed=1 input.mxf
```

**Use Cases for Full Parse (1.0):**
- Calculate exact frame counts in VBR files without headers (raw H.264 streams)
- Detect CRC errors in audio
- Verify file isn't truncated

## 3. Broadcast-Specific Capabilities

MediaInfo supports specific metadata structures that FFprobe often misses or hides in binary blobs.

### Ancillary Data & Hidden Streams

**Dolby E Detection:**
MediaInfo analyzes PCM tracks to detect SMPTE 337M headers. It will report:
- `Format: Dolby E`
- `Muxing mode: SMPTE 337M`
- `Program configuration: 5.1+2`

**Captions/Subtitles:**
It identifies presence (not content) of:
- CEA-608/708 (in MPEG-2 User Data, SEI, or SMPTE 436M)
- Teletext (System B)
- DVB Subtitles

**Timecode:**
It reports *multiple* timecode tracks if present:
- `Time code of first frame: 10:00:00:00`
- `Time code source: Material / Source`

### Container Support

**Legacy Formats:**
- GXF (General Exchange Format)
- LXF (Leitch)
- AVI
- QuickTime Reference

**Modern Formats:**
- MXF (OP1a, OP-Atom, AS-11)
- IMF (CPL parsing)
- MPEG-TS

## 4. Advanced Usage: MediaTrace

**MediaTrace** (`--Details=1`) is MediaInfo's "Nuclear Option" for debugging. It dumps the **physical structure** of the file (atoms, blocks, partitions) rather than just the metadata.

### Command

```bash
mediainfo --Details=1 --Output=XML input.mxf > trace_dump.xml
```

### What It Reveals

**MP4/MOV:**
- Exact hierarchy of atoms (`ftyp`, `moov`, `trak`, `mdia`)
- Whether `free` atom is wasting space
- Whether `moov` atom is at the end (bad for streaming)

**MXF:**
- Every **KLV Triplet**
- `PartitionPack`, `PrimerPack` structure
- Exact byte offset of every `IndexTableSegment`

**Use Case:**
If a file is rejected by a broadcast server, MediaTrace allows you to compare the *structure* of a good file vs. a bad file byte-for-byte.

## 5. Output Formats & Automation

For professional pipelines, raw text output is insufficient. Use **XML** or **JSON**.

### JSON Output (Modern Standard)

```bash
mediainfo --Output=JSON input.mp4
```

Returns a structured object:
```json
{
  "media": {
    "@ref": "/path/to/input.mp4",
    "track": [
      { "@type": "General", "Format": "MPEG-4", ... },
      { "@type": "Video", "Format": "AVC", "Format_Profile": "High@L4.1", ... },
      { "@type": "Audio", "Format": "AAC", ... }
    ]
  }
}
```

**Note:** All values are strings. You must cast `"Duration": "10.000"` to a float in your code.

### Custom Templates (`--Inform` / `--Output`)

For ultra-fast, specific data extraction (e.g., just the bitrate), avoid parsing the whole JSON. Use a custom template:

```bash
# Single field
mediainfo --Output="Video;%BitRate%" input.mp4
# Output: 50000000

# Multiple fields
mediainfo --Output="Video;%BitRate%,%FrameRate%" input.mp4
# Output: 50000000,25.000

# Multiple stream types
mediainfo --Output="General;Container: %Format%\n" \
          --Output="Video;Codec: %Format% %Format_Profile%\n" \
          --Output="Video;Resolution: %Width%x%Height%\n" \
          --Output="Other;Timecode: %TimeCode_FirstFrame%\n" \
          input.mxf
```

### Available Template Fields

**General:**
- `%Format%` - Container format
- `%Duration%` - Duration in milliseconds
- `%Duration/String3%` - Duration as HH:MM:SS.mmm
- `%FileSize%` - File size in bytes
- `%OverallBitRate%` - Overall bitrate

**Video:**
- `%Format%` - Codec name
- `%Format_Profile%` - Codec profile (e.g., "AVC-Intra 100")
- `%Width%`, `%Height%` - Resolution
- `%FrameRate%` - Frame rate
- `%BitDepth%` - Bit depth
- `%ColorSpace%` - Color space
- `%ChromaSubsampling%` - Chroma subsampling

**Audio:**
- `%Format%` - Codec name
- `%Channels%` - Channel count
- `%SamplingRate%` - Sample rate
- `%BitDepth%` - Bit depth

**Other (Timecode):**
- `%TimeCode_FirstFrame%` - First frame timecode
- `%TimeCode_Source%` - Timecode source

## 6. Integration Examples

### Bash Script

```bash
#!/bin/bash
# Extract key broadcast metadata

FILE="$1"

echo "=== $FILE ==="
mediainfo --Output="General;Format: %Format%\nDuration: %Duration/String3%\n" "$FILE"
mediainfo --Output="Video;Video: %Format% %Format_Profile% %Width%x%Height% @ %FrameRate% fps\n" "$FILE"
mediainfo --Output="Audio;Audio: %Format% %Channels% ch @ %SamplingRate% Hz\n" "$FILE"
mediainfo --Output="Other;Timecode: %TimeCode_FirstFrame%\n" "$FILE"
```

### Python (`pymediainfo`)

Do not subprocess `mediainfo` strings. Use the wrapper:

```python
from pymediainfo import MediaInfo

media_info = MediaInfo.parse("master_file.mxf")

for track in media_info.tracks:
    if track.track_type == "Video":
        print(f"Codec: {track.format}")
        print(f"Profile: {track.format_profile}")
        print(f"Duration: {track.duration} ms")
        # Access obscure fields dynamically
        if hasattr(track, "active_format_description"):
             print(f"AFD: {track.active_format_description}")
    elif track.track_type == "Other":
        if hasattr(track, "time_code_first_frame"):
            print(f"Timecode: {track.time_code_first_frame}")
```

### Swift (via Process)

```swift
func getMediaInfo(for fileURL: URL) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mediainfo")
    process.arguments = ["--Output=JSON", fileURL.path]

    let pipe = Pipe()
    process.standardOutput = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
```

## 7. Comparison: MediaInfo vs. FFprobe

| Feature | MediaInfo | FFprobe |
| :--- | :--- | :--- |
| **Philosophy** | "Tell me what the headers say this is." | "Tell me what the decoder sees." |
| **Speed** | Instant (Header read) | Slower (Stream analysis) |
| **Dolby E** | **Yes** (Detects inside PCM) | No (Sees it as PCM noise) |
| **Text/Captions** | High-level (e.g., "CEA-608 present") | Low-level (Dumps raw CC packets) |
| **Loudness** | **Metadata only** (Reads tags) | **Analysis** (Calculates true EBU R128) |
| **Structure** | **MediaTrace** (Block/Atom view) | `-show_packets` (Packet view) |
| **Codec Profile** | Human-readable ("AVC-Intra 100") | Technical ("avc1.640028") |
| **Best For** | Ingest, Quick QC, MAM Indexing | Deep QC, Playback verification, Decoding errors |

## 8. MXF-Specific Features

MediaInfo excels at MXF analysis, providing information FFprobe often lacks:

### Operational Pattern Detection

```bash
mediainfo --Output="General;OP: %Format_Profile%\n" input.mxf
# Output: "OP: OP-Atom" or "OP: OP-1a"
```

### Package Information

MediaInfo reports:
- Material Package UMID
- Source Package UMID
- Package creation date/time

### Index Table Analysis

With MediaTrace, you can inspect:
- Index Table Segment locations
- Edit Unit Byte Count (CBR detection)
- Key frame offsets

## 9. Limitations & "Gotchas"

### 1. Loudness

MediaInfo **does not calculate loudness**. If it reports "Loudness: -23 LUFS", it is just reading a metadata tag someone wrote into the header. That tag could be incorrect.

**Solution:** Use FFmpeg for true measurement:
```bash
ffmpeg -i input.mxf -af ebur128 -f null -
```

### 2. P2 Spanning

MediaInfo can read P2 XML files (`.xml`) to see the whole clip, but if you point it at a single `.mxf` video file from a spanned set, it will only report that segment's duration.

**Solution:** Parse the P2 XML separately or use BMX which understands spanning.

### 3. Validation

MediaInfo is **permissive**. It will tell you "This is an MXF file" even if the essence is corrupt 10 seconds in. It assumes if the header is valid, the file is valid.

**Solution:** For validation, use a full file scan:
```bash
ffmpeg -i input.mxf -f null -
```

### 4. String Values

All JSON values are strings, even numbers:
```json
{ "Duration": "10000", "Width": "1920" }
```
You must cast these in your code.

## 10. Quick Reference

### Essential Commands

```bash
# Basic info (text)
mediainfo input.mxf

# JSON output
mediainfo --Output=JSON input.mxf

# Specific fields only
mediainfo --Output="Video;%Format% %Format_Profile%" input.mxf

# Timecode
mediainfo --Output="Other;%TimeCode_FirstFrame%" input.mxf

# Full structure dump
mediainfo --Details=1 --Output=XML input.mxf

# Fast header-only parse
mediainfo --ParseSpeed=0 input.mxf

# List all available fields
mediainfo --Info-Parameters
```

### Common Template Fields

| Field | Stream Type | Description |
|-------|-------------|-------------|
| `%Format%` | All | Format name |
| `%Format_Profile%` | Video | Codec profile |
| `%Duration%` | General | Duration (ms) |
| `%Duration/String3%` | General | Duration (HH:MM:SS.mmm) |
| `%Width%` | Video | Width in pixels |
| `%Height%` | Video | Height in pixels |
| `%FrameRate%` | Video | Frame rate |
| `%BitDepth%` | Video/Audio | Bit depth |
| `%Channels%` | Audio | Channel count |
| `%SamplingRate%` | Audio | Sample rate |
| `%TimeCode_FirstFrame%` | Other | Start timecode |

---

## Sources

1. pymediainfo Documentation - ReadTheDocs
2. MediaInfo - MediaArea.net
3. MediaInfo CLI Mastery: Complete Container Analysis Guide - probe.dev
4. MediaInfo Command Line Interface - fossies.org
5. Rethinking Broadcast Workflow Management with AI - Digital Nirvana
6. mediainfo-parser examples - CodeSandbox
7. MediaInfo - Fields - MediaArea.net
8. Process JSON data from mediainfo output - Stack Overflow
9. MediaInfo CLI Syntax Teaching - Stack Overflow
10. Impact of Workflow design & Integration in broadcast media - WorkflowLabs
11. Issue parsing multiple large video files with MediaInfoDLL - Stack Overflow
12. Chocolatey Software | MediaInfo
13. pymediainfo API reference - ReadTheDocs
14. MediaInfo - Quick start SDK - MediaArea.net
15. MediaCentral Workflows for Broadcast Journalists - YouTube
16. MediaInfoLib/MediaInfo.h - GitHub
17. MediaInfo - Supported formats - MediaArea.net
18. MediaInfo README - GitHub
19. MediaInfo CLI command - VideoHelp forum
20. MediaInfo - Testimonials - MediaArea.net
21. greatseth/mediainfo README - GitHub
22. Fastest way to get media file duration - Stack Overflow
23. pymediainfo API reference - ReadTheDocs
24. MediaInfo History_GUI.txt - GitHub
25. How to read media file info using Visual C++ - Stack Overflow
26. mediainfo.js Usage - Documentation
27. MediaInfo ChangeLog - MediaArea.net
28. Dolby Vision and Mediainfo HDR Format - MakeMKV forum
29. MediaInfo Version History - VideoHelp
30. Finding the deepest AV metadata with MediaConch and MediaTrace - Blog
31. pymediainfo - PyPI
32. When does MI read the whole file versus only the header? - SourceForge
33. MediaConch/History_CLI.txt - GitHub
34. MediaInfoLib/File_Mpeg4.cpp - GitHub
35. Extract video information - VideoHelp forum
36. pymediainfo Documentation PDF
37. How to understand MediaInfo CSV files - Stack Overflow
38. File_Mpega.cpp - MediaInfoLib GitHub
