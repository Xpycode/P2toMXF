# FFmpeg & FFprobe: Deep Technical Analysis for Broadcast Workflows

## Executive Overview

While proprietary systems like Panasonic's P2 ecosystem rely on rigid, hardware-specific structures, **FFmpeg** serves as the software-defined engine of modern broadcast infrastructure. It is not merely a "converter" but a complete multimedia handling framework built on a modular architecture of libraries. For broadcast engineers, understanding FFmpeg requires moving beyond basic command-line usage to understanding its internal pipeline, specifically how it demuxes containers (like MXF), decodes essence (like AVC-Intra), and allows for granular analysis via **FFprobe**.

## 1. Internal Architecture & Pipeline

FFmpeg is not a monolithic application but a collection of inter-dependent libraries. Understanding these is critical for debugging why a specific P2 or MXF file might fail to ingest or transcode.

### Core Libraries

| Library | Function | Broadcast Relevance |
| :--- | :--- | :--- |
| **libavformat** | Muxing/Demuxing | Handles the MXF container parsing. It reads the KLV structure, partitions, and Index Tables discussed in the previous report. |
| **libavcodec** | Encoding/Decoding | Contains the specific decoders for DVCPRO-HD, AVC-Intra, and DNxHD. It operates on raw bitstreams. |
| **libavfilter** | Filtering | The engine for EBU R128 loudness normalization, scaling, deinterlacing, and burn-in timecode. |
| **libavutil** | Utilities | Core math functions, random number generators, and data structure handling (like `AVFrame` and `AVPacket`). |
| **libswscale** | Color/Scaling | Handles pixel format conversion (e.g., YUV422P10LE to YUV420P) and color space transformation (BT.709 to BT.2020). |
| **libavdevice** | I/O Devices | Handles capture from DeckLink cards or other hardware interfaces. |

### The Transcoding Pipeline

When you run a command, data flows through a strict pipeline. Understanding this helps isolate where quality loss or metadata stripping occurs.

1.  **Demuxer (libavformat):** Reads input file (e.g., P2 MXF). Separates video, audio, and data streams. Parses KLV metadata.
2.  **Decoder (libavcodec):** Takes encoded packets and produces raw uncompressed frames (`AVFrame`).
3.  **Filter Graph (libavfilter):** Processes raw frames. This is where deinterlacing, scaling, or loudness normalization happens.
4.  **Encoder (libavcodec):** Compresses raw frames into new packets (e.g., encodes to ProRes or H.264).
5.  **Muxer (libavformat):** Wraps encoded packets into the output container (e.g., MXF OP1a).

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Demuxer   │───▶│   Decoder   │───▶│   Filters   │───▶│   Encoder   │───▶│    Muxer    │
│ libavformat │    │ libavcodec  │    │ libavfilter │    │ libavcodec  │    │ libavformat │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
     MXF              AVPacket           AVFrame           AVPacket            MXF/MOV
   Container          (encoded)        (raw pixels)       (encoded)          Container
```

## 2. FFmpeg for P2 & MXF Workflows

FFmpeg does not natively "mount" a P2 card structure like an NLE. It treats P2 contents as individual files. You must bridge the gap between P2's physical structure and FFmpeg's file-centric logic.

### Handling P2 Structures (OP-Atom)

As established, P2 uses **OP-Atom** (separate video/audio files). FFmpeg requires you to manually map these separate elements if you want to create a single playable file (OP1a).

**The "Rewrap" Workflow (P2 -> OP1a):**

To convert a P2 clip (`0009E7.MXF` video + 4 audio tracks) into a single broadcast master without re-encoding (rewrapping):

```bash
ffmpeg \
  -i CONTENTS/VIDEO/0009E7.MXF \        # Input 0: Video
  -i CONTENTS/AUDIO/0009E700.MXF \      # Input 1: Audio Ch1
  -i CONTENTS/AUDIO/0009E701.MXF \      # Input 2: Audio Ch2
  -i CONTENTS/AUDIO/0009E702.MXF \      # Input 3: Audio Ch3
  -i CONTENTS/AUDIO/0009E703.MXF \      # Input 4: Audio Ch4
  -map 0:v:0 \                          # Map Video from Input 0
  -map 1:a:0 -map 2:a:0 -map 3:a:0 -map 4:a:0 \ # Map Audio streams
  -c copy \                             # Copy codecs (No Transcode)
  -f mxf \                              # Force MXF OP1a output
  -timecode 01:00:00:00 \               # Manually write Start TC (optional override)
  output_master.mxf
```

**Important Limitation:** FFmpeg's MXF muxer may fail with AVC-Intra due to frame size padding mismatches. This is why P2toMXF uses BMX for the initial rewrap step.

### Handling Spanned Clips

Unlike Avid Media Composer, FFmpeg does not read `LASTCLIP.TXT` to automatically join spanned clips. You must concatenate them.

*   **Concat Demuxer:** Create a text file (`list.txt`) containing `file 'part1.mxf'`, `file 'part2.mxf'`.
*   **Command:** `ffmpeg -f concat -safe 0 -i list.txt -c copy output.mxf`
*   **Risk:** If the P2 metadata (LASTCLIP) indicated a discontinuity that you ignore, you may lose audio sync at the stitch point.

### MXF Specific Flags

When writing MXF files for broadcast delivery (e.g., AS-11/DPP), specific flags in `libavformat` control the KLV structure:

*   `-g`: Set keyframe interval (GOP size). For XDCAM HD422 compliance, this must be 12 (NTSC) or 12/24 (PAL).
*   `-min_partition_duration`: Controls how often Body Partitions are inserted (important for streaming MXF).
*   `-store_user_data 1`: Forces writing of user data (like captions) into the MPEG-2 bitstream.

### Stream Mapping Reference

Understanding `-map` is critical for P2 workflows:

```bash
# Map specific streams
-map 0:v:0          # First video stream from input 0
-map 0:a:0          # First audio stream from input 0
-map 0:a            # All audio streams from input 0
-map 0              # All streams from input 0

# Negative mapping (exclude)
-map 0 -map -0:s    # All streams except subtitles from input 0

# Map by metadata
-map 0:m:language:eng  # Streams with language=eng metadata
```

## 3. Broadcast Compliance & QC Filters

FFmpeg includes powerful internal filters for automated Quality Control (QC), allowing you to detect issues without watching the footage.

### EBU R128 Loudness Normalization

Instead of blindly normalizing peaks, use the `loudnorm` filter which implements the EBU R128 standard (integrated loudness target -23 LUFS).

**Single-Pass (approximate):**
```bash
ffmpeg -i input.mxf -af loudnorm=I=-23:LRA=7:tp=-1.5 -c:v copy output.mxf
```

**Two-Pass (precise, recommended for broadcast):**
```bash
# Pass 1: Analyze
ffmpeg -i input.mxf -af loudnorm=I=-23:LRA=7:tp=-1.5:print_format=json -f null - 2>&1 | grep -A 12 "loudnorm"

# Pass 2: Apply with measured values
ffmpeg -i input.mxf -af loudnorm=I=-23:LRA=7:tp=-1.5:measured_I=-25.3:measured_LRA=8.2:measured_tp=-3.1:measured_thresh=-35.2:offset=0.5 -c:v copy output.mxf
```

Parameters:
*   `I`: Integrated loudness target (-23 LUFS for EBU R128)
*   `LRA`: Loudness Range target
*   `tp`: True Peak limit (-1 dBTP recommended)

### Loudness Measurement (Analysis Only)

```bash
ffmpeg -i input.mxf -af ebur128=peak=true -f null - 2>&1 | grep -E "I:|LRA:|Peak:"
```

### Black and Freeze Detection

Useful for finding commercial breaks or technical faults (dead air).

**blackdetect:** Logs timestamps where video is black for a set duration.
```bash
ffmpeg -i input.mxf -vf "blackdetect=d=2:pix_th=0.00" -an -f null - 2>&1 | grep blackdetect
```
*   `d=2`: Minimum black duration (2 seconds)
*   `pix_th=0.00`: Pixel threshold (0 = pure black only)

**freezedetect:** Detects if the video has frozen (identical frames).
```bash
ffmpeg -i input.mxf -vf "freezedetect=n=-60dB:d=2" -an -f null - 2>&1 | grep freeze
```
*   `n=-60dB`: Noise tolerance
*   `d=2`: Minimum freeze duration

### Silence Detection

```bash
ffmpeg -i input.mxf -af "silencedetect=n=-50dB:d=2" -vn -f null - 2>&1 | grep silence
```

### Signal Generation

For creating leader/slate files:

**SMPTE Color Bars:**
```bash
ffmpeg -f lavfi -i smptebars=size=1920x1080:rate=25 -t 10 -c:v prores_ks output_bars.mov
```

**HD Color Bars with 1kHz Tone:**
```bash
ffmpeg -f lavfi -i "smptehdbars=size=1920x1080:rate=25" \
       -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
       -t 30 -c:v prores_ks -c:a pcm_s24le output_bars_tone.mov
```

**Test Pattern with Timecode:**
```bash
ffmpeg -f lavfi -i "testsrc=size=1920x1080:rate=25" \
       -vf "drawtext=text='%{pts\:hms}':fontsize=72:fontcolor=white:x=(w-tw)/2:y=h-100" \
       -t 60 -c:v prores_ks output_test.mov
```

## 4. FFprobe: The Deep Analysis Tool

FFprobe is the inspection engine. For broadcast, the default output is insufficient. You need structured data (XML/JSON) to parse KLV and structural metadata.

### Data Views

FFprobe sees a file in four layers of depth:

| View | Flag | Content |
|------|------|---------|
| **Format** | `-show_format` | Container level (duration, overall bitrate, wrapper metadata) |
| **Streams** | `-show_streams` | Codec details, timebase, pixel format, color primaries |
| **Packets** | `-show_packets` | Encoded chunks of data. Critical for debugging muxing overhead or VBR |
| **Frames** | `-show_frames` | Decoded images. Shows `pict_type` (I/B/P), interlacing, per-frame metadata |

### Basic Analysis Commands

**Quick Overview:**
```bash
ffprobe -hide_banner input.mxf
```

**Detailed Stream Info:**
```bash
ffprobe -v error -show_streams -show_format input.mxf
```

**JSON Output (for scripting):**
```bash
ffprobe -v quiet -print_format json -show_format -show_streams input.mxf > analysis.json
```

### Advanced MXF Analysis Commands

**1. Inspecting GOP Structure (I/B/P cadence):**

To verify if a stream is truly Intra-frame (like AVC-Intra) or Long-GOP (like XDCAM):
```bash
ffprobe -select_streams v:0 -show_frames -show_entries frame=pict_type,key_frame,pkt_pts_time -of csv input.mxf
```
*   Output: `frame,I,1,0.000000` (Shows I-frame, Keyframe=True)
*   If you see `P` or `B` frames in a supposedly "All-Intra" format, the file is non-compliant

**2. Extracting Timecode:**

MXF timecode is often buried in stream or format tags:
```bash
ffprobe -v error -show_entries stream_tags=timecode:format_tags=timecode -of default=noprint_wrappers=1 input.mxf
```

**3. Frame Count and Duration:**
```bash
ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames,duration -of default=noprint_wrappers=1 input.mxf
```

**4. Pixel Format and Color Space:**
```bash
ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,color_space,color_primaries,color_transfer -of default=noprint_wrappers=1 input.mxf
```

**5. Audio Channel Layout:**
```bash
ffprobe -v error -select_streams a -show_entries stream=channels,channel_layout,sample_rate,bits_per_sample -of default=noprint_wrappers=1 input.mxf
```

**6. Dumping KLV & "Dark" Metadata:**

FFmpeg doesn't natively parse every proprietary KLV packet into human-readable text, but it can dump the raw data for inspection:
```bash
ffprobe -show_data -show_packets -select_streams d input.mxf
```
*   `-select_streams d`: Selects data streams (where non-audio/video essence lives)
*   `-show_data`: Prints the hexadecimal content of the packets

**7. Bitrate Analysis Per Frame:**
```bash
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,size -of csv input.mxf | head -100
```

### Output Format Options

```bash
-of default          # Key=value pairs (default)
-of csv              # Comma-separated values
-of json             # JSON (best for parsing)
-of xml              # XML
-of flat             # Flat key=value with dots
```

## 5. Hardware Acceleration

In high-throughput broadcast environments (e.g., ingest farms), CPU encoding is a bottleneck. FFmpeg supports hardware offloading:

### Apple VideoToolbox (macOS)

```bash
# Decode with hardware
ffmpeg -hwaccel videotoolbox -i input.mxf -c:v copy output.mov

# Encode with hardware
ffmpeg -i input.mxf -c:v h264_videotoolbox -b:v 50M output.mov

# ProRes encoding (always uses VideoToolbox)
ffmpeg -i input.mxf -c:v prores_videotoolbox -profile:v 3 output.mov
```

### NVIDIA NVENC/NVDEC

```bash
# Hardware decode + encode
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i input.mxf -c:v h264_nvenc -preset slow output.mp4

# With scaling on GPU
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i input.mxf -vf scale_cuda=1280:720 -c:v h264_nvenc output.mp4
```

### Intel VAAPI (Linux)

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 -i input.mxf -vf 'format=nv12,hwupload' -c:v h264_vaapi output.mp4
```

### Warning for Broadcast

Hardware encoders (NVENC/VAAPI/VideoToolbox) historically struggle with:
- Strict bitrate targets (CBR) required for broadcast
- Compliant GOP structures required for broadcast headers (like AS-11)
- Precise frame-accurate encoding

**Recommendation:** Use software encoding (`libx264` / `prores_ks`) for "Gold Master" creation. Reserve hardware encoding for proxy generation or streaming where slight variations are acceptable.

## 6. Common Broadcast Commands

### Rewrap MXF to MOV (No Transcode)
```bash
ffmpeg -i input.mxf -c copy -f mov output.mov
```

### Transcode to ProRes 422 HQ
```bash
ffmpeg -i input.mxf -c:v prores_ks -profile:v 3 -c:a pcm_s24le output.mov
```

ProRes profiles:
- `0` = Proxy
- `1` = LT
- `2` = Standard (422)
- `3` = HQ (422 HQ)
- `4` = 4444
- `5` = 4444 XQ

### Transcode to DNxHD
```bash
ffmpeg -i input.mxf -c:v dnxhd -profile:v dnxhr_hq -c:a pcm_s24le output.mxf
```

### Extract Audio Channels to Separate Files
```bash
ffmpeg -i input.mxf -map 0:a:0 -c:a pcm_s24le ch1.wav
ffmpeg -i input.mxf -map 0:a:1 -c:a pcm_s24le ch2.wav
```

### Burn-In Timecode
```bash
ffmpeg -i input.mxf -vf "drawtext=timecode='01\:00\:00\:00':rate=25:fontsize=48:fontcolor=white:x=100:y=100" -c:a copy output.mov
```

### Create Proxy with Timecode
```bash
ffmpeg -i input.mxf \
  -vf "scale=1280:720,drawtext=timecode='01\:00\:00\:00':rate=25:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.5:x=10:y=10" \
  -c:v libx264 -preset fast -crf 23 \
  -c:a aac -b:a 128k \
  proxy.mp4
```

## 7. Summary of Limitations

### P2 Metadata
FFmpeg ignores the XML files in the `CLIP` folder. It reads only the embedded MXF metadata. If you rely on user-entered metadata from the camera (Shot Mark, Reporter Name) stored *only* in the XML, FFmpeg will discard it during a rewrap.

### Growing Files
FFmpeg can read growing MXF files, but it often fails to detect the updating duration unless specifically compiled/configured or if the file has a compliant "Open/Incomplete" Header Partition.

### AVC-Intra MXF Muxing
FFmpeg's MXF muxer has known issues with AVC-Intra due to frame size padding calculations. The error:
```
[mxf @ 0x...] track 0: frame size does not match index unit size
```
**Workaround:** Use BMX for AVC-Intra MXF creation, then FFmpeg for subsequent operations.

### Strict Validation
While FFmpeg is robust, it is "permissive." It will play non-compliant MXF files that a hardware playout server might reject. Always use a dedicated QC tool (like Baton, Vidchecker, or the BMX library's validator) alongside FFmpeg for broadcast delivery verification.

### Metadata Preservation
Not all metadata survives transcoding. Specifically:
- Custom KLV packets may be stripped
- Timecode may need explicit preservation with `-timecode`
- Color metadata (primaries, transfer, matrix) may need explicit flags

---

## Quick Reference Card

### Essential FFprobe Commands
```bash
# Basic info
ffprobe -hide_banner input.mxf

# JSON output for scripting
ffprobe -v quiet -print_format json -show_format -show_streams input.mxf

# Timecode
ffprobe -v error -show_entries format_tags=timecode input.mxf

# Frame types (GOP analysis)
ffprobe -select_streams v:0 -show_frames -show_entries frame=pict_type -of csv input.mxf | head -50

# Duration and frame count
ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames,duration input.mxf
```

### Essential FFmpeg Commands
```bash
# Rewrap (no transcode)
ffmpeg -i input.mxf -c copy output.mov

# Transcode to ProRes HQ
ffmpeg -i input.mxf -c:v prores_ks -profile:v 3 -c:a pcm_s24le output.mov

# Concatenate files
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mxf

# Loudness normalize
ffmpeg -i input.mxf -af loudnorm=I=-23:tp=-1 -c:v copy output.mxf

# Extract audio
ffmpeg -i input.mxf -vn -c:a pcm_s24le output.wav
```

---

## Sources

1. Build a High-Performance Video Pipeline in Java 25 with FFmpeg
2. FFmpeg Formats Documentation - ffmpeg.org
3. FFmpeg Concat Made Easy - Cloudinary
4. FFmpeg library compile - Stack Overflow
5. ffmpeg-all(1) - Arch manual pages
6. How to concatenate videos using ffmpeg - Mux
7. Using FFMPEG and LibAV - Stack Overflow
8. Material Exchange Format - Wikipedia
9. Concatenating Videos Using FFmpeg - Baeldung
10. FFmpeg Official Documentation - ffmpeg.org
11. ffmpeg Documentation - ffmpeg.org
12. Concatenate - FFmpeg Wiki
13. FFmpeg Documentation
14. Ubuntu Manpage: ffmpeg-formats
15. FFmpeg - Concat videos with different time base
16. Developer Documentation - ffmpeg.org
17. FFMPEG full options - GitHub Gist
18. Concat transition issues - Reddit r/ffmpeg
19. FFmpeg libav tutorial - GitHub
20. FFMPEG conversion to MXF - Stack Overflow
21. How to get xml/json output from ffprobe
22. ffprobe -show_packets vs. -show_frames - Reddit
23. How to pull timecode using AWK and ffmpeg
24. Loudness analysis and correction - Stack Overflow
25. ffprobe - Comprehensive Tutorial - OTTVerse
26. ffprobe media prober - Ubuntu manpages
27. ffprobe Documentation - Pasteur
28. rendiff-probe - GitHub
29. FFprobe Tutorial - ffmpeg-api.com
30. ffprobe-all(1) - Arch manual pages
31. Extracting starting timecode info - FFmpeg mailing list
32. Cutdetection and analysis - FFmpeg mailing list
33. ffprobe Documentation - ffmpeg.org
34. ffprobe Documentation - ffmpeg.org
35. Extracting timecode - FFmpeg narkive
36. FFmpeg documentation: ffprobe
37. What is FFprobe? - IOriver
38. Getting log line for each extracted frame
39. Batch extract timecode - VideoHelp forum
40. ffmprovisr - AMIA Open Source
41. Using FFmpeg with NVIDIA GPU - NVIDIA docs
42. De-telecine PAL - VideoHelp forum
43. Generate video from FFmpeg filter
44. FFmpeg Protocols Documentation
45. HEVC Encoding: CPU vs VAAPI - Reddit
46. FFmpeg Filters Documentation
47. Generate smptebars - FFmpeg by Example
48. Unimplemented mxf OP1a feature - FFmpeg Trac
49. FFmpeg VAAPI encoding - Stack Overflow
50. Deinterlacing HD footage with FFMPEG
51. NVENC vs FFMPEG VAAPI - Reddit
52. NVDEC frame dropping with deinterlacing - NVIDIA forums
53. FFmpeg test video patterns
54. libavformat/mxfdec.c - FFmpeg source
55. FFMpeg Advanced encoding with hardware - GitHub Gist
56. FFMPEG Deinterlace - AISeesoft
57. Generate SMPTE Color Bars - GitHub Gist
58. MXF, OP1A, DNxHD corruption - FFmpeg mailing list
59. ffmpeg ebur128 filter - Technical Reference
60. Does ffmpeg support KLV metadata?
61. Using BlackDetect Filter - GDELT Project
62. Problem with OP atom mxf files - LWKS Forum
63. Setting D10 MXF metadata - FFmpeg mailing list
64. Normalize audio to EBU R128 - Stack Overflow
65. FFmpeg filters - Ubuntu manpages
66. FFmpeg Concatenate Videos - YouTube
67. FFmpeg for Audio: Encoding, Filtering & Normalization - Cincopa
68. FFmpeg/libavformat/mxfenc.c - GitHub
69. blackdetect filter output to textfile
70. MXF OP-Atom Transcodes Not Linking - Reddit
71. Setting color flags in D10 MXF - FFmpeg mailing list
72. ffmpeg-normalize PyPI
73. Decode ANC data in MXF - Reddit
74. FilteringGuide - FFmpeg Wiki
