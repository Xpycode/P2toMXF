# P2toMXF

A native macOS app that merges Panasonic P2 card clips into self-contained MXF or MOV files — **without re-encoding**.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Version](https://img.shields.io/github/v/release/Xpycode/P2toMXF)
[![Download](https://img.shields.io/badge/Download-Latest-brightgreen)](https://github.com/Xpycode/P2toMXF/releases/latest)
![Downloads](https://img.shields.io/github/downloads/Xpycode/P2toMXF/total)

## The Problem

Panasonic P2 cameras (AJ-PX5000G, AJ-HPX, VariCam LT, etc.) record in **MXF OP-Atom** — video and each audio channel are separate files:

```
CONTENTS/
├── VIDEO/
│   └── 0001AB.MXF        ← video only (AVC-Intra)
└── AUDIO/
    ├── 0001AB00.MXF      ← audio channel 1
    ├── 0001AB01.MXF      ← audio channel 2
    ├── 0001AB02.MXF      ← audio channel 3
    └── 0001AB03.MXF      ← audio channel 4
```

Most NLEs handle this fine. But MAM systems, archive workflows, and delivery specs often require **a single self-contained file** (MXF OP1a or MOV).

**FFmpeg can't do this** for P2 AVC-Intra — it chokes on Panasonic's proprietary frame padding:
```
[mxf @ ...] track 0: frame size does not match index unit size, 568320 != 568832
```

P2toMXF solves this using the **BMX toolkit** (BBC) which has Panasonic-specific lookup tables, then chains to FFmpeg for concatenation. The result is bit-for-bit identical video and audio — only the container changes.

## Screenshots

<!-- Replace these with actual screenshots -->
<!-- ![Main window](03_Screenshots/main-window.png) -->
<!-- ![Queue processing](03_Screenshots/queue-processing.png) -->

*Screenshots coming soon*

## Features

- **Merge & Concatenate** — Combine multiple clips into a single output file
- **Individual Export** — Rewrap each clip to its own self-contained file
- **Batch Queue** — Queue multiple jobs, process sequentially
- **Multi-Card Loading** — Load all P2 cards from a parent folder at once (Cmd+O)
- **Output Verification** — Quick or full decode tests on converted files
- **Timecode Preservation** — Original P2 timecodes carried through
- **Audio Remapping** — All channels, stereo mix, or mono
- **Time Estimation** — Learns from past conversions for accurate ETAs
- **Sleep Prevention** — Keeps Mac awake during long batch runs

| Output | Container | Typical Use |
|--------|-----------|-------------|
| **MXF OP1a** | `.mxf` | Broadcast, MAM, archive |
| **QuickTime** | `.mov` | NLE editing, general delivery |

## Installation

1. Download the latest DMG from [**Releases**](https://github.com/Xpycode/P2toMXF/releases/latest)
2. Open the DMG and drag P2toMXF to Applications
3. On first launch, right-click > Open (macOS Gatekeeper)

**Requirements:** macOS 14.0+ (Sonoma), Apple Silicon (arm64)

### Build from Source

```bash
git clone https://github.com/Xpycode/P2toMXF.git
cd P2toMXF
open 01_Project/P2toMXF.xcodeproj
```

Build with Xcode 16+ (Cmd+B). All dependencies (FFmpeg, BMX) are bundled in the project.

## Usage

1. **Load a P2 Card** — Cmd+O or click "Load P2 Card". Select a card or a folder containing multiple cards.
2. **Select Clips** — Click clips to select, or use Select All. Clips are grouped by recording span.
3. **Choose Settings** — Output format (MXF/MOV), mode (Merge/Individual), audio mapping
4. **Set Output** — Choose destination folder and filename
5. **Convert** — "Convert Now" for immediate processing, or "Add to Queue" for batch

| Shortcut | Action |
|----------|--------|
| Cmd+O | Open P2 card picker |
| Cmd+A | Select all clips |

## How It Works

```
P2 Card (OP-Atom)    BMX              FFmpeg
┌─────────────┐   ┌──────────┐    ┌──────────┐
│ VIDEO/*.MXF │──▶│bmxtrans- │───▶│ concat   │───▶ Final
│ AUDIO/*.MXF │   │wrap -t   │OP1a│ demuxer  │     MXF/MOV
└─────────────┘   │op1a      │    └──────────┘
                  └──────────┘
```

1. **BMX rewraps** each P2 clip (1 video + 4 audio files) into a single OP1a MXF
2. **FFmpeg concatenates** the OP1a MXFs into the final output (stream copy, no re-encoding)

All operations are stream copy — no transcoding. Typical throughput:

| Operation | Speed |
|-----------|-------|
| BMX rewrap | ~30x realtime |
| FFmpeg concat | ~60x realtime |
| 16 clips merged | ~1-2 minutes |

### Bundled Tools

Everything runs self-contained — no Homebrew, no PATH setup:

| Tool | Version | Purpose |
|------|---------|---------|
| FFmpeg | 8.0.1 | Concatenation, verification, thumbnails |
| bmxtranswrap | 1.2 | OP-Atom to OP1a rewrapping |
| mxf2raw | 1.2 | MXF inspection |

## Project Structure

```
01_Project/P2toMXF/
├── P2toMXFApp.swift                      # App entry point
├── ContentView.swift                     # Main three-column layout
├── ConversionViewModel.swift             # Core state
├── ConversionViewModel+CardManagement.swift
├── ConversionViewModel+Conversion.swift
├── ConversionViewModel+RecordGroups.swift
├── Models/
│   ├── P2Clip.swift                      # P2 card/clip data models
│   ├── ConversionJob.swift               # Queue job model
│   ├── ProgressModels.swift              # Metrics, estimates
│   └── VerificationModels.swift
├── Services/
│   ├── P2CardParser.swift                # P2 XML metadata parsing
│   ├── FFmpegWrapper.swift               # FFmpeg process management
│   ├── FFmpegWrapper+Conversion.swift    # Rewrap and merge logic
│   ├── FFmpegWrapper+Thumbnails.swift    # Frame extraction
│   ├── BMXWrapper.swift                  # BMX toolkit wrapper
│   ├── QueueManager.swift                # Job queue + persistence
│   ├── QueueManager+Processing.swift
│   ├── QueueManager+Operations.swift
│   ├── QueueManager+Verification.swift
│   ├── VerificationService.swift         # Decode verification
│   ├── SpeedTracker.swift                # Historical speed data
│   └── ThumbnailManager.swift            # Async thumbnail cache
├── Views/                                # SwiftUI views
└── Resources/
    ├── ffmpeg, bmxtranswrap, mxf2raw     # Bundled binaries
    └── lib/                              # BMX dylibs
```

## Building BMX from Source

Only needed if you want to update the bundled BMX version:

```bash
brew install cmake uriparser expat
git clone https://github.com/bbc/bmx.git
cd bmx && mkdir -p out/build && cd out/build
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/expat;/opt/homebrew/opt/uriparser"
cmake ../../ -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)
```

See `CLAUDE.md` for library bundling and code signing details.

## License

MIT License. See [LICENSE](LICENSE) for details.

### Third-Party Licenses

- **FFmpeg** — LGPL/GPL ([ffmpeg.org](https://ffmpeg.org))
- **BMX** — BSD 3-Clause ([github.com/bbc/bmx](https://github.com/bbc/bmx))

## Contributing

Contributions welcome. See `CLAUDE.md` for architecture documentation.

## Acknowledgments

- [BBC BMX Project](https://github.com/bbc/bmx) — the MXF toolkit that makes this possible
- [FFmpeg](https://ffmpeg.org) — multimedia Swiss Army knife
- App icon by NanoBanana
