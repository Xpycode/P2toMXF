# BMX (Broadcast Media Exchange) Library: Advanced Technical Overview

## Executive Summary

BMX (Broadcast Media Exchange) is a specialized, open-source library and utility suite maintained by the BBC and EBU, specifically architected for the strict compliance requirements of professional broadcast environments. Unlike FFmpeg, which prioritizes broad compatibility, BMX prioritizes **specification adherence** to SMPTE standards (ST 377-1, ST 378, ST 390, RDD-9). It serves as the reference implementation for many broadcast standards including AS-11 (UK DPP) and is critical for workflows requiring technically compliant MXF files that will pass rigid Quality Control (QC) checks.

## 1. Internal Architecture

BMX is not a single tool but a layered architecture providing different levels of abstraction for MXF handling.

### Core Libraries

| Library | Language | Role | Broadcast Relevance |
| :--- | :--- | :--- | :--- |
| **libMXF** | C | Low-level Core | The foundational library that handles raw KLV encoding/decoding, partition management, and index table generation. It provides granular access to the physical MXF file structure. |
| **libMXF++** | C++ | Wrapper | An object-oriented wrapper around `libMXF` that simplifies essence container handling and metadata management. |
| **bmx** | C++ | Application Layer | The high-level library built on `libMXF++` that implements specific "flavors" (Application Specifications) like AS-11, AS-02, and P2. |

### Library Dependency Chain

```
┌─────────────────────────────────────────────────────┐
│                    bmx (C++)                        │
│         Application Layer & CLI Tools              │
│     (raw2bmx, bmxtranswrap, mxf2raw)              │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                 libMXF++ (C++)                      │
│        Object-Oriented MXF Abstraction             │
│     (Tracks, Packages, Descriptors as objects)     │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                  libMXF (C)                         │
│            Low-Level KLV I/O Layer                 │
│   (Partition packs, Index tables, Raw KLV R/W)    │
└─────────────────────────────────────────────────────┘
```

### Architectural Philosophy

BMX operates on an "essence-aware" model. Unlike generic muxers, it understands the specific constraints of broadcast codecs (AVC-Intra, D-10, XDCAM) and enforces them.

*   **Compliance First:** It will often refuse to wrap essence that violates a target profile (e.g., wrong GOP structure for XDCAM), whereas FFmpeg might allow it.
*   **Shim Support:** It natively supports "shims" – constrained profiles for specific delivery targets (e.g., `AS11_DPP_HD`).
*   **Manufacturer LUTs:** Contains lookup tables for manufacturer-specific frame padding schemes (Panasonic, Sony), which is why it succeeds where FFmpeg fails with AVC-Intra MXF muxing.

## 2. Command Line Tools & Usage

BMX provides a suite of CLI tools that function differently from FFmpeg's unified interface.

### raw2bmx: Essence Wrapping

Creates MXF files from raw essence streams (H.264, PCM, Wave). This is the primary tool for creating compliant masters from disparate sources.

**Basic Usage:**
```bash
raw2bmx -t <type> -o output.mxf [options] input_files...
```

**Example: Creating a UK DPP (AS-11) Master:**
```bash
raw2bmx \
  -t as11op1a \                 # Target Type: AS-11 OP1a
  -o program_master.mxf \       # Output Filename
  -y 10:00:00:00 \              # Start Timecode
  --avci100_1080i \             # Video Format: AVC-Intra 100 1080i
  video.h264 \                  # Input Video Essence
  --wave audio_stereo.wav       # Input Audio (Wave)
```

**Key Feature:** The `-t` flag sets the "flavour." BMX automatically enforces all KLV constraints, partition sizes, and metadata requirements for that specific flavour.

**Common Target Types:**
| Type | Description |
|------|-------------|
| `op1a` | Generic OP1a MXF |
| `as10` | AS-10 (MXF for Production) |
| `as11op1a` | AS-11 OP1a (UK DPP) |
| `as02` | AS-02 (MXF Versioning) |
| `rdd9` | RDD-9 (Sony XDCAM HD) |
| `d10` | SMPTE D-10 (IMX) |
| `avid` | Avid OP-Atom |

### bmxtranswrap: Rewrapping

Rewraps existing MXF files into new MXF variants without re-encoding essence. Crucial for converting between Operational Patterns (e.g., P2 OP-Atom to Broadcast OP1a).

**Basic Usage:**
```bash
bmxtranswrap -t <type> -o output.mxf input_files...
```

**Example: Converting P2 (OP-Atom) to OP1a:**
```bash
bmxtranswrap \
  -t op1a \                     # Target: OP1a
  -o output_file.mxf \
  VIDEO/0234LZ.MXF \            # P2 Video File
  AUDIO/0234LZ00.MXF \          # P2 Audio Ch1
  AUDIO/0234LZ01.MXF \          # P2 Audio Ch2
  AUDIO/0234LZ02.MXF \          # P2 Audio Ch3
  AUDIO/0234LZ03.MXF            # P2 Audio Ch4
```

**Example: Converting P2 to AS-10 (MXF for Production):**
```bash
bmxtranswrap \
  -t as10 \                     # Target: AS-10
  -o output_file.mxf \
  input_video.mxf \
  input_audio00.mxf \
  input_audio01.mxf
```

**Common Options:**
| Option | Description |
|--------|-------------|
| `-t <type>` | Target MXF type/flavor |
| `-o <file>` | Output filename |
| `-y <tc>` | Start timecode (HH:MM:SS:FF) |
| `--clip <name>` | Set clip name metadata |
| `--dur <frames>` | Limit output duration |
| `--part <interval>` | Partition interval (frames) |

### mxf2raw: Analysis & Extraction

Extracts raw essence and XML metadata. It is arguably more precise than FFprobe for validating structural compliance because it validates against the SMPTE dictionaries it implements.

**Basic Analysis:**
```bash
mxf2raw -i input.mxf
```

**Extract Raw Essence:**
```bash
mxf2raw --video input.mxf       # Extract video essence
mxf2raw --audio input.mxf       # Extract audio essence
```

**Detailed Structure Analysis:**
```bash
mxf2raw -i --info-file info.txt input.mxf
```

**Example: Extracting ADM (Audio Definition Model) Metadata:**
```bash
mxf2raw --chna-text-out chna.txt --wave-chunks-out xml_chunks input.mxf
```
This allows extraction of Dolby Atmos or Next Generation Audio (NGA) metadata that is often invisible to standard tools.

## 3. Advanced P2 & MXF Capabilities

BMX excels where general-purpose tools fail, particularly with complex metadata and spanning.

### P2 Support (OP-Atom)

BMX has native understanding of the Panasonic P2 structure.

**Spanned Clips:** `bmxtranswrap` correctly identifies and stitches P2 spanned clips if you provide the first segment. It reads the internal metadata to find the subsequent parts.

**Metadata Preservation:** Unlike FFmpeg, `bmxtranswrap` preserves complex proprietary metadata (like P2's user clip names or XML-based metadata) when moving between MXF flavors.

**Reference Matrix Handling:** BMX correctly interprets P2's "reference matrix" structure where each file has 5 stream slots but only one contains actual data. It extracts only the valid essence.

### Frame Size Padding (Why BMX Succeeds Where FFmpeg Fails)

The critical advantage BMX has over FFmpeg for P2 workflows:

```
FFmpeg MXF Muxer Calculation:     568,832 bytes/frame (from AVC-Intra spec)
Panasonic P2 Actual Frame Size:  568,320 bytes/frame
Difference:                       512 bytes (proprietary padding)
```

BMX contains **manufacturer-specific lookup tables** that map codec identifiers to their actual frame sizes, including Panasonic's proprietary padding scheme. This is why:

- **BMX**: Successfully rewraps P2 AVC-Intra to OP1a
- **FFmpeg**: Fails with "frame size does not match index unit size"

### Broadcast-Specific Features

1.  **RDD-9 (XDCAM) Compliance:** Enforces the specific MPEG-2 Long GOP structure required by Sony hardware.

2.  **AS-11 UK DPP:** Natively handles the "Descriptive Metadata Schemes" (DMS) required for UK delivery, allowing you to insert production data (Director, Synopsis) directly into the MXF header.

3.  **Active Format Description (AFD):** Can inject AFD codes into the generic container system item, critical for aspect ratio control in broadcast.

4.  **Timecode Handling:** Proper handling of multiple timecode tracks, drop-frame flags, and user bits.

## 4. Supported Formats

### Wrapper Types (Output)

| Type | Standard | Description |
|------|----------|-------------|
| OP1a | ST 378 | Single item, interleaved tracks |
| OP-Atom | ST 390 | Single essence per file |
| AS-02 | AMWA | Versioning/component-based |
| AS-10 | AMWA | MXF for Production |
| AS-11 | AMWA | UK DPP delivery |
| RDD-9 | SMPTE | Sony XDCAM HD |
| D-10 | ST 386 | IMX (MPEG-2 422P@ML) |
| Avid | Proprietary | Avid OP-Atom |

### Supported Essence Types

**Video:**
- AVC-Intra (Class 50, 100, 200, 4:4:4)
- MPEG-2 Long GOP (XDCAM HD, HDV)
- MPEG-2 I-frame (D-10/IMX)
- DV/DVCPRO/DVCPRO-HD
- DNxHD/DNxHR (VC-3)
- JPEG 2000
- JPEG XS
- Apple ProRes
- Uncompressed (UYVY, v210)
- VC-2 (Dirac Pro)

**Audio:**
- PCM (16/24 bit, 48kHz)
- Broadcast Wave (BWF)
- AES3 wrapped audio

**Data:**
- IMSC 1 Timed Text (subtitles)
- VBI/ANC data
- ADM (Audio Definition Model)

## 5. Comparison: BMX vs. FFmpeg

| Feature | FFmpeg | BMX |
| :--- | :--- | :--- |
| **Primary Goal** | Universal format conversion | Strict SMPTE/Broadcast compliance |
| **MXF OP1a** | Generic implementation | Strictly profiled (AS-11, RDD-9) |
| **P2 Handling** | Manual mapping required | Native P2 awareness |
| **AVC-Intra MXF** | Fails (padding mismatch) | Works (manufacturer LUTs) |
| **Metadata** | Basic KLV support | Deep support for DMS-1, AS-11, ADM |
| **Verification** | Permissive (plays anything) | Strict (fails on non-compliance) |
| **Performance** | High (optimized ASM) | Moderate (Reference implementation) |
| **Transcoding** | Full encode/decode | Rewrap only (no transcoding) |
| **License** | LGPL/GPL | BSD 3-Clause |

## 6. Integration Workflow

In a professional pipeline, BMX and FFmpeg are often used in tandem:

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source    │───▶│   FFmpeg    │───▶│    BMX      │───▶│   Output    │
│  (P2 Card)  │    │  (Decode/   │    │ (Compliant  │    │ (Broadcast  │
│             │    │   Encode)   │    │   Wrap)     │    │   Master)   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### Strategy 1: BMX for Rewrap, FFmpeg for Concat

This is the approach used by P2toMXF:

1. **BMX (`bmxtranswrap`)**: Rewrap P2 OP-Atom files to OP1a MXF
2. **FFmpeg (concat demuxer)**: Concatenate multiple OP1a files into final output

### Strategy 2: FFmpeg Encode, BMX Wrap

For creating new broadcast masters:

1. **FFmpeg**: Encode raw video to AVC-Intra bitstream
2. **BMX (`raw2bmx`)**: Wrap bitstream into compliant AS-11 MXF with proper metadata

### Strategy 3: BMX for QC Validation

Use `mxf2raw` to validate files before delivery:

```bash
# Check structure
mxf2raw -i delivery_master.mxf

# Extract info for QC report
mxf2raw -i --info-format xml --info-file qc_report.xml delivery_master.mxf
```

## 7. Building BMX from Source

### Dependencies

```bash
# macOS (Homebrew)
brew install cmake uriparser expat

# Ubuntu/Debian
apt-get install cmake liburiparser-dev libexpat1-dev
```

### Build Steps

```bash
git clone https://github.com/ebu/bmx.git
cd bmx
mkdir -p out/build && cd out/build

# macOS: Set paths for Homebrew dependencies
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/expat;/opt/homebrew/opt/uriparser"

cmake ../../ -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)
```

### Bundling for App Distribution

After building, fix library paths for app bundle inclusion:

```bash
# Copy binaries and libs
cp bmxtranswrap mxf2raw /path/to/Resources/
mkdir /path/to/Resources/lib
cp *.dylib /path/to/Resources/lib/

# Fix paths to look in Resources/lib/
install_name_tool -change @rpath/libbmx.1.dylib @executable_path/lib/libbmx.1.dylib bmxtranswrap
install_name_tool -change @rpath/libMXF++.1.dylib @executable_path/lib/libMXF++.1.dylib bmxtranswrap
install_name_tool -change @rpath/libMXF.1.dylib @executable_path/lib/libMXF.1.dylib bmxtranswrap
# (repeat for mxf2raw and all library cross-references)

# Re-sign after modifying
codesign --force --sign - bmxtranswrap mxf2raw lib/*.dylib
```

## 8. Quick Reference

### Essential bmxtranswrap Commands

```bash
# P2 to OP1a (what P2toMXF does)
bmxtranswrap -t op1a -o output.mxf VIDEO/*.MXF AUDIO/*.MXF

# P2 to AS-10
bmxtranswrap -t as10 -o output.mxf VIDEO/*.MXF AUDIO/*.MXF

# Set timecode
bmxtranswrap -t op1a -y 10:00:00:00 -o output.mxf input.mxf

# Limit duration (in frames)
bmxtranswrap -t op1a --dur 1000 -o output.mxf input.mxf
```

### Essential mxf2raw Commands

```bash
# Basic info
mxf2raw -i input.mxf

# Detailed info to file
mxf2raw -i --info-file info.txt input.mxf

# Extract video essence
mxf2raw --video -o video_out input.mxf

# Extract audio essence
mxf2raw --audio -o audio_out input.mxf
```

---

## Sources

1. bmx - GitHub (ebu/bmx)
2. bmx - BBC Open Source
3. bmx/docs/audio_definition_model.md - GitHub
4. Native P2 Editing in Final Cut Pro with MXF4mac - YouTube
5. rzkn/bmx - Gitee
6. Use BMXTranswrap in isolation - SourceForge discussion
7. Help creating a simple MXF file - SourceForge discussion
8. Elecard DirectShow Codec SDK documentation
9. raw2bmx to make OP-Atom files - SourceForge discussion
10. bmx - how to use this software - SourceForge discussion
11. bbc/bmx: Library and utilities - GitHub
12. bmx / Bmx / SourceForge
13. Looking for raw P2 .MXF sample footage - DVXuser
14. Linker Error building Xcode project - Stack Overflow
15. bmx/docs/imf_prores_track_files.md - GitHub
16. Problems importing P2 files – MXF workaround - Creative COW
17. Research & Development White Paper - BBC R&D
18. FFAStrans forum discussion
19. BBC-archive/libMXF - GitHub
20. Ingex Installation Guide - SourceForge
21. libMXF memory mapped file implementation - SourceForge discussion
