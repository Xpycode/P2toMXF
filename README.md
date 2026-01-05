# P2toMXF

A native macOS app that merges Panasonic P2 card clips into self-contained MXF or MOV files — **without re-encoding**.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Why This Tool Exists

Panasonic P2 cameras record in **MXF OP-Atom** format, where video and each audio channel are stored as separate files:

```
CONTENTS/
├── VIDEO/
│   └── 0001AB.MXF        ← video only
└── AUDIO/
    ├── 0001AB00.MXF      ← audio channel 1
    ├── 0001AB01.MXF      ← audio channel 2
    ├── 0001AB02.MXF      ← audio channel 3
    └── 0001AB03.MXF      ← audio channel 4
```

This format works well for NLE editing, but many MAM systems, archive solutions, and broadcast workflows expect **MXF OP1a** or **MOV** — a single self-contained file with video and all audio streams interleaved.

P2toMXF converts OP-Atom to OP1a/MOV **without re-encoding**. Video and audio remain bit-for-bit identical; only the container changes.

### Why Not Just Use FFmpeg?

FFmpeg's MXF muxer fails with P2 AVC-Intra content due to frame size padding mismatches:
```
[mxf @ ...] track 0: frame size does not match index unit size, 568320 != 568832
```

P2toMXF solves this by using the **BMX toolkit** (developed by BBC) which has manufacturer-specific lookup tables for Panasonic's padding scheme, then chains to FFmpeg for concatenation.

## Features

- **Merge & Concatenate** — Combine multiple clips into a single output file
- **Individual Export** — Rewrap each clip to its own self-contained file
- **Batch Queue** — Queue multiple conversion jobs for sequential processing
- **Multi-Card Loading** — Load all P2 cards from a parent folder at once
- **Output Verification** — Quick or full decode tests to verify converted files
- **Timecode Preservation** — Maintains original P2 timecodes
- **Time Estimation** — Historical speed tracking for accurate conversion estimates
- **Sleep Prevention** — Keeps Mac awake during long conversions

### Output Formats

| Format | Container | Use Case |
|--------|-----------|----------|
| **MXF OP1a** | `.mxf` | Broadcast, MAM, archive |
| **QuickTime** | `.mov` | NLE editing, general use |

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon** (arm64) — Intel builds possible but not pre-built

## Installation

### Download Release
Download the latest `.dmg` from [Releases](../../releases) and drag to Applications.

### Build from Source
```bash
git clone https://github.com/yourusername/P2toMXF.git
cd P2toMXF
open P2toMXF.xcodeproj
```

Build with Xcode 16+ (Cmd+B). All dependencies (FFmpeg, BMX) are bundled.

## Usage

1. **Load a P2 Card** — Click "Load P2 Card" or press Cmd+O
2. **Select Clips** — Check the clips you want to convert
3. **Choose Settings** — Pick output format (MXF/MOV) and mode (Merge/Individual)
4. **Set Output** — Choose destination folder and filename
5. **Convert** — Click "Convert Now" or add to queue for batch processing

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+O | Open P2 card picker |
| Cmd+A | Select all clips |

## Technical Details

### The Pipeline

```
P2 Card (OP-Atom)    BMX              FFmpeg
┌─────────────┐   ┌──────────┐    ┌──────────┐
│ VIDEO/*.MXF │──▶│bmxtrans- │───▶│ concat   │───▶ Final
│ AUDIO/*.MXF │   │wrap -t   │OP1a│ demuxer  │     MXF/MOV
└─────────────┘   │op1a      │    └──────────┘
                  └──────────┘
```

1. **BMX rewraps** each P2 clip (1 video + 4 audio files) → single OP1a MXF
2. **FFmpeg concatenates** the OP1a MXFs → final output (stream copy, no re-encoding)

### Bundled Tools

All tools are bundled inside the app (no external dependencies):

| Tool | Version | Purpose |
|------|---------|---------|
| FFmpeg | 8.0.1 | Concatenation, verification |
| bmxtranswrap | 1.2 | OP-Atom to OP1a rewrapping |
| mxf2raw | 1.2 | MXF inspection |

### Performance

All operations use stream copy (no transcoding):
- **BMX rewrap**: ~30x realtime
- **FFmpeg concat**: ~60x realtime
- **Typical throughput**: 16 clips in ~1-2 minutes

## Building BMX from Source

If you need to rebuild BMX:

```bash
brew install cmake uriparser expat
git clone https://github.com/bbc/bmx.git
cd bmx && mkdir -p out/build && cd out/build
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/expat;/opt/homebrew/opt/uriparser"
cmake ../../ -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)
```

See `CLAUDE.md` for detailed bundling and code signing instructions.

## Project Structure

```
P2toMXF/
├── P2toMXFApp.swift          # App entry point
├── ContentView.swift         # Main UI
├── ConversionViewModel.swift # State management
├── Models/
│   └── P2Clip.swift          # Data models
├── Services/
│   ├── P2CardParser.swift    # P2 XML metadata parsing
│   ├── FFmpegWrapper.swift   # FFmpeg integration
│   ├── BMXWrapper.swift      # BMX toolkit wrapper
│   ├── QueueManager.swift    # Batch queue management
│   ├── VerificationService.swift
│   └── SpeedTracker.swift
├── Views/
│   ├── QueueListView.swift   # Queue panel
│   ├── ClipRowView.swift     # Clip list items
│   └── ...
└── Resources/
    ├── ffmpeg                # Bundled FFmpeg
    ├── bmxtranswrap          # Bundled BMX
    ├── mxf2raw
    └── lib/                  # BMX dependencies
```

## License

MIT License. See [LICENSE](LICENSE) for details.

### Third-Party Licenses

- **FFmpeg** — LGPL/GPL ([ffmpeg.org](https://ffmpeg.org))
- **BMX** — BSD 3-Clause ([github.com/bbc/bmx](https://github.com/bbc/bmx))

## Contributing

Contributions welcome! Please read the technical documentation in `CLAUDE.md` before submitting PRs.

## Acknowledgments

- [BBC BMX Project](https://github.com/bbc/bmx) for the excellent MXF toolkit
- [FFmpeg](https://ffmpeg.org) for the multimedia Swiss Army knife
- App icon by NanoBanana
