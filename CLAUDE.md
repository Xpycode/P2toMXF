# P2toMXF Project

## Project Location
`/Users/sim/XcodeProjects/1-macOS/P2toMXF`

## Status: WORKING ✓
Successfully merges P2 card clips into single MXF/MOV files using BMX + FFmpeg pipeline.

---

## Architecture

### App Files
- `P2toMXF.xcodeproj/` - Xcode project
- `P2toMXF/P2toMXFApp.swift` - App entry point
- `P2toMXF/ContentView.swift` - Main UI with clip list, console output panel
- `P2toMXF/ConversionViewModel.swift` - State management, merge orchestration
- `P2toMXF/Models/P2Clip.swift` - Data models for clips, cards, settings
- `P2toMXF/Services/P2CardParser.swift` - Parses P2 XML metadata
- `P2toMXF/Services/FFmpegWrapper.swift` - FFmpeg + BMX integration
- `P2toMXF/Services/BMXWrapper.swift` - BMX toolkit wrapper

### Bundled Tools (in Resources/)
```
Resources/
├── ffmpeg           (59MB) - FFmpeg 8.0.1 arm64
├── bmxtranswrap     (268KB) - BMX rewrap tool
├── mxf2raw          (252KB) - BMX inspection tool
└── lib/
    ├── libbmx.1.dylib       (2.2MB)
    ├── libMXF++.1.dylib     (634KB)
    ├── libMXF.1.dylib       (805KB)
    ├── libexpat.1.dylib     (163KB)
    └── liburiparser.1.dylib (145KB)
```

### Build Settings
- **Sandbox**: DISABLED (required for subprocess execution)
- **Hardened Runtime**: ENABLED (required for distribution/notarization)
- **ENABLE_USER_SCRIPT_SANDBOXING**: NO (required for Run Script build phase)
- **Development Team**: FDMSRXXN73
- **Deployment Target**: macOS 14.0

### Entitlements (P2toMXF.entitlements)
```xml
com.apple.security.cs.disable-library-validation    <!-- Load bundled dylibs -->
com.apple.security.cs.allow-unsigned-executable-memory  <!-- FFmpeg codecs -->
com.apple.security.cs.allow-jit                     <!-- JIT compilation -->
```

### Bundled Binary Signing
All bundled executables and dylibs must be signed with Hardened Runtime before distribution.
Run `./sign-bundled-binaries.sh` to sign with your development certificate.
For notarization, use: `./sign-bundled-binaries.sh "Developer ID Application: Your Name (TEAMID)"`

### Build Phases
- **Run Script** phase copies `lib/` folder to bundle:
  ```bash
  ditto "${SRCROOT}/P2toMXF/Resources/lib" "${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/lib"
  ```
- The `lib` folder is NOT in Xcode project navigator (removed reference to prevent linking issues)

---

## P2 Card Structure (Panasonic)

```
CONTENTS/
├── CLIP/           # XML metadata: {ClipName}.XML
├── VIDEO/          # Video MXF: {ClipName}.MXF (AVC-Intra, OPAtom)
├── AUDIO/          # Audio MXF: {ClipName}00-03.MXF (4 mono channels)
├── ICON/           # Thumbnails
├── PROXY/          # Low-res MP4 proxies
└── AVCLIP/         # (typically empty)
```

### File Relationships
For clip `0234LZ`:
- XML: `CLIP/0234LZ.XML`
- Video: `VIDEO/0234LZ.MXF` (1 file, AVC-Intra)
- Audio: `AUDIO/0234LZ00.MXF` through `AUDIO/0234LZ03.MXF` (4 files)

### P2 MXF "Reference Matrix" Structure
Each MXF has 5 stream slots but only ONE contains actual data:

| File | Stream 0 | Stream 1 | Stream 2 | Stream 3 | Stream 4 |
|------|----------|----------|----------|----------|----------|
| VIDEO/*.MXF | **H.264** | placeholder | placeholder | placeholder | placeholder |
| AUDIO/*00.MXF | placeholder | **PCM Ch1** | placeholder | placeholder | placeholder |
| AUDIO/*01.MXF | placeholder | placeholder | **PCM Ch2** | placeholder | placeholder |
| AUDIO/*02.MXF | placeholder | placeholder | placeholder | **PCM Ch3** | placeholder |
| AUDIO/*03.MXF | placeholder | placeholder | placeholder | placeholder | **PCM Ch4** |

### Key XML Fields
```xml
<Video ValidAudioFlag="false">  <!-- Audio in video MXF is NOT usable -->
  <Codec>AVC-I_1080/25p</Codec>
  <StartTimecode>18:09:34:24</StartTimecode>
</Video>
<Audio>...</Audio>  <!-- 4 elements = 4 channels in separate files -->
```

---

## The Core Problem & Solution

### Why FFmpeg Alone Fails
FFmpeg's MXF muxer fails with P2 AVC-Intra:
```
[mxf @ 0x...] track 0: frame size does not match index unit size, 568320 != 568832
```

**Root cause**: MXF uses Index Tables for random access, requiring exact frame size prediction:
- FFmpeg calculates: 568,832 bytes/frame (from AVC-Intra spec)
- P2 actual frames: 568,320 bytes/frame
- Difference: 512 bytes (Panasonic's padding scheme)

FFmpeg uses generic calculation; P2 cameras use proprietary padding.

### Why BMX Works
BMX (BBC MXF toolkit) has manufacturer-specific lookup tables for padding schemes, including Panasonic P2.

### The Working Pipeline
```
P2 Card (OPAtom)     BMX                    FFmpeg
┌─────────────┐   ┌─────────────┐      ┌─────────────┐
│ VIDEO/*.MXF │─┬─│bmxtranswrap │─────▶│ concat      │───▶ Final
│ AUDIO/*.MXF │─┘ │ -t op1a     │ OP1a │ demuxer     │     MXF/MOV
└─────────────┘   └─────────────┘ MXF  └─────────────┘
```

1. **BMX rewraps** each P2 clip (5 files) → single OP1a MXF
2. **FFmpeg concatenates** the OP1a MXFs → final output (stream copy, fast)

---

## Working Commands

### Single Clip Rewrap (BMX)
```bash
bmxtranswrap -t op1a -o output.mxf \
  VIDEO/0234LZ.MXF \
  AUDIO/0234LZ00.MXF AUDIO/0234LZ01.MXF \
  AUDIO/0234LZ02.MXF AUDIO/0234LZ03.MXF
```

### Single Clip to MOV (FFmpeg - also works)
```bash
ffmpeg -i VIDEO/0234LZ.MXF \
  -i AUDIO/0234LZ00.MXF -i AUDIO/0234LZ01.MXF \
  -i AUDIO/0234LZ02.MXF -i AUDIO/0234LZ03.MXF \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:a:0 -map 4:a:0 \
  -c:v copy -c:a copy -timecode 18:09:34:24 \
  -f mov -y output.mov
```

### Concatenate Multiple Clips
```bash
# After BMX rewrap of each clip:
echo "file 'clip1.mxf'" > concat.txt
echo "file 'clip2.mxf'" >> concat.txt

ffmpeg -f concat -safe 0 -i concat.txt \
  -c copy -map 0:v -map 0:a \
  -timecode 18:09:34:24 -f mxf -y output.mxf
```

---

## Building BMX from Source

```bash
# Install dependencies
brew install cmake uriparser expat

# Clone and build
git clone https://github.com/ebu/bmx.git
cd bmx && mkdir -p out/build && cd out/build
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/expat;/opt/homebrew/opt/uriparser"
cmake ../../ -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)
```

### Bundling BMX for App Distribution
After building, fix library paths:
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

---

## Xcode Setup Notes

### Adding lib folder to bundle (what worked)
1. Do NOT add `lib/` folder to Xcode project navigator (causes linking issues)
2. Use **Run Script** build phase:
   ```bash
   ditto "${SRCROOT}/P2toMXF/Resources/lib" "${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/lib"
   ```
3. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` in Build Settings

### Common Issues
- **SIGABRT at launch**: lib folder was added to project, causing Xcode to link dylibs. Fix: remove lib folder reference from project navigator.
- **Sandbox denial in Run Script**: Set `ENABLE_USER_SCRIPT_SANDBOXING = NO`
- **dylib version warnings**: Can be ignored (built on newer macOS, runs fine on older)

---

## Performance
- **BMX rewrap**: ~30x realtime (stream copy)
- **FFmpeg concat**: ~60x realtime (stream copy)
- **Single 2-min clip**: ~4-5 seconds
- **16 clips concatenated**: ~1-2 minutes

---

## Test P2 Card
- **Location**: `/Volumes/1TB-exFAT/Silvesterkonzert 2025 P2 K1 3v4`
- **Clips**: 16, AVC-I_1080/25p @ 50fps, 4 audio channels each
- **Camera**: Panasonic AJ-PX5000G
- **Content**: Continuous recording split across multiple files (every ~X GB)

---

## Future Enhancements
1. ~~**Batch rewrap mode**: Rewrap each clip to self-contained file (no concatenation)~~ ✓ Done
2. ~~**Output format selection**: MXF vs MOV option in UI~~ ✓ Done
3. **XML metadata copy**: Option to copy P2 XML alongside output
4. ~~**Per-clip export**: For NLE workflows needing original timecodes~~ ✓ Done (Individual mode)
5. **Progress parsing**: Parse BMX output for better progress reporting
6. **Large binary handling**: Consider download script instead of storing ffmpeg (59MB) in repo
   - Option A: `download-deps.sh` script fetching from https://evermeet.cx/ffmpeg/
   - Option B: Xcode build phase that downloads if missing
   - Option C: Git LFS for large file storage
7. ~~**Multi-job queueing**: Queue multiple conversion tasks and execute sequentially~~ ✓ Done

---

## Session Log: 2026-01-01 (Initial Build)

### What We Discovered
1. P2 uses OPAtom MXF with "reference matrix" - 5 stream slots per file, only 1 has data
2. `ValidAudioFlag="false"` in XML means video MXF audio is NOT usable
3. FFmpeg MXF muxer fails due to frame size padding mismatch (568320 vs 568832 bytes)
4. MOV container works with FFmpeg (records sizes after encoding, not predictive)
5. BMX toolkit has Panasonic-specific lookup tables that handle padding correctly

### What We Built
1. Built BMX from source with Homebrew dependencies
2. Created BMXWrapper.swift service
3. Updated FFmpegWrapper.swift with BMX + FFmpeg pipeline
4. Bundled BMX binaries + dylibs in app Resources
5. Fixed library paths with install_name_tool for @executable_path/lib/
6. Added Run Script build phase for copying lib folder
7. Disabled user script sandboxing to allow file copying

### Key Files Modified
- `Services/BMXWrapper.swift` (new)
- `Services/FFmpegWrapper.swift` (updated with BMX integration)
- `Resources/bmxtranswrap`, `mxf2raw`, `lib/*.dylib` (new)
- `CLAUDE.md` (comprehensive documentation)

---

## Session Log: 2026-01-01 (Refinements)

### New Features Added

#### 1. Custom Output Filename
- User can specify output filename for merged file
- Required field (button disabled until entered)
- Hidden in Individual mode (uses clip names)

#### 2. Container Format Selection
- Picker to choose MOV or MXF output format
- Applies to both Concatenate and Individual modes

#### 3. Processing Mode Selection
- **Merge & Concatenate**: Combines all clips into single file (original behavior)
- **Individual Files**: Rewraps each clip to its own self-contained file

#### 4. Timecode Continuity Check
- Detects gaps/overlaps between consecutive clips when concatenating
- Shows warning in UI and blocks merge if discontinuous
- User can switch to Individual mode or deselect problematic clips

#### 5. Duration Display
- Each clip shows duration in HH:MM:SS:FF format
- Properly converted from P2 edit units to timecode frames

### P2 XML Parsing Fixes

#### EditUnit Conversion (Critical Bug Fix)
```xml
<Duration>6432</Duration>
<EditUnit>1/50</EditUnit>
```
- **Problem**: Duration is in edit units (1/50 sec), not TC frames
- **Fix**: Convert `duration_tc_frames = edit_units × (tc_rate / edit_rate)`
- Example: 6432 × (25/50) = 3216 TC frames

#### Frame Rate Priority (Critical Bug Fix)
```xml
<Codec>AVC-I_1080/25p</Codec>    <!-- TC rate: 25fps -->
<FrameRate>50p</FrameRate>        <!-- Sensor rate: 50fps -->
```
- **Problem**: `<FrameRate>` element (sensor rate) was overwriting TC rate from `<Codec>`
- **Fix**: Added `frameRateFromCodec` flag - once Codec sets TC rate, FrameRate is ignored
- TC operations now correctly use 25fps from codec string

### Key Files Modified
- `Models/P2Clip.swift` - Added `OutputContainer`, `ProcessingMode` enums, `Timecode` struct
- `ContentView.swift` - Redesigned footer with mode/format/filename controls, TC warning display
- `ConversionViewModel.swift` - Added TC check logic, `canConvert`, individual conversion mode
- `Services/P2CardParser.swift` - Fixed EditUnit conversion and frame rate priority

### Architecture Notes

#### ConversionSettings (P2Clip.swift)
```swift
struct ConversionSettings {
    var outputDirectory: URL?
    var outputFilename: String = ""
    var outputContainer: OutputContainer = .mov  // .mov or .mxf
    var processingMode: ProcessingMode = .concatenate  // .individual or .concatenate
    var preserveTimecode: Bool = true
    var audioMapping: AudioMapping = .allChannels
}
```

#### Timecode Struct (P2Clip.swift)
```swift
struct Timecode {
    let hours, minutes, seconds, frames: Int
    let frameRate: Double

    init?(string: String, frameRate: Double)  // Parse "HH:MM:SS:FF"
    var totalFrames: Int                       // Convert to absolute frames
    static func frameGap(...) -> Int           // Check continuity
}
```

#### TC Continuity Check (ConversionViewModel.swift)
```swift
var timecodeIssues: [(clip1: P2Clip, clip2: P2Clip, gapFrames: Int)]
// Returns non-empty array if gaps/overlaps detected between consecutive clips
// gap > 0: missing frames, gap < 0: overlapping frames
```

---

## Session Log: 2026-01-01 (UI Polish & App Icon)

### UI Improvements

#### Footer Reorganization
- **Row 1**: Format, Mode, Audio, Preserve TC (inline labels, horizontal)
- **Row 2**: Output directory + "Use folder name" checkbox + Filename field
- **Row 3**: Action button (right-aligned)

#### Layout Fixes
- Minimum window width: 600 → 850 pixels
- All labels use consistent font size (removed `.font(.caption)`)
- Added `.fixedSize()` to prevent label text wrapping
- Filename field expands to fill available space (`maxWidth: .infinity`)
- "Use folder name" checkbox auto-fills P2 card folder name

#### Header Cleanup
- Moved "Load P2 Card" button to left side
- Removed FFmpeg version display (now in About panel)
- Kept "FFmpeg not found" warning for error feedback

### App Icon & About Panel

#### App Icon Setup
- Generated all macOS icon sizes from 1024px source (NanoBanana design)
- Sizes: 16, 32, 64, 128, 256, 512, 1024 pixels
- Added to `AppIcon.appiconset` with proper Contents.json
- Created `AboutIcon.imageset` for potential custom About view

#### Credits (About Panel)
- Created `Credits.rtf` with clickable links:
  - **FFmpeg** (ffmpeg.org) - LGPL/GPL license
  - **BMX** (github.com/bbc/bmx) - BSD 3-Clause license
  - Icon credit to NanoBanana
- Standard macOS About panel now shows icon + credits

### New Settings
- `useFolderNameAsFilename: Bool` - Auto-use P2 card folder name
- `effectiveOutputFilename` computed property in ViewModel

### Files Modified
- `ContentView.swift` - Footer layout, header cleanup
- `ConversionViewModel.swift` - Added `effectiveOutputFilename`
- `Models/P2Clip.swift` - Added `useFolderNameAsFilename` setting
- `Assets.xcassets/AppIcon.appiconset/` - All icon sizes
- `Assets.xcassets/AboutIcon.imageset/` - About view icon
- `Credits.rtf` - About panel credits with links

---

## Session Log: 2026-01-01 (Batch Queue)

### Multi-Job Queue Implementation
Enables users to queue multiple independent conversion tasks and execute them sequentially. Decouples "setup" from "execution" - users can configure jobs while others run.

### New Data Structures

#### JobStatus Enum (P2Clip.swift)
```swift
enum JobStatus: Equatable {
    case pending       // Waiting in queue
    case preparing     // Gathering files/rewrapping
    case active        // FFmpeg is processing
    case completed     // Successfully finished
    case failed(String) // Error encountered
    case cancelled     // User cancelled
}
```

#### ConversionJob Struct (P2Clip.swift)
```swift
struct ConversionJob: Identifiable {
    let id: UUID
    let cardName: String          // Source P2 card name
    let cardPath: URL             // For security-scoped access
    let clips: [P2Clip]           // Clips to process
    let settings: ConversionSettings
    let destinationURL: URL       // Final output path
    let createdAt: Date
    var status: JobStatus = .pending
    var progress: Double = 0.0    // 0.0 to 1.0
}
```

### QueueManager Service (Services/QueueManager.swift)
Central singleton service managing the job queue:
- **Queue Storage**: Array of `ConversionJob` objects
- **Sequential Execution**: Picks next pending job automatically
- **Service Orchestration**: Communicates with FFmpegWrapper
- **Security Scoped Access**: Handles `startAccessingSecurityScopedResource()` for each job
- **Status Tracking**: Updates job status and progress in real-time

### QueueListView (Views/QueueListView.swift)
Collapsible panel showing the queue:
- **Job Rows**: Card name, clip count, format, status icon, progress bar
- **Job Controls**: Remove pending, retry failed, clear finished
- **Global Controls**: Cancel current, cancel all pending

### UI Integration (ContentView.swift)
- **"Add to Queue" Button**: Next to Convert, queues current selection
- **Queue Toggle**: Header button shows/hides queue panel with badge
- **Console Integration**: Shows queue output when processing
- **Feedback Message**: Temporary "Added X jobs to queue" confirmation

### ViewModel Integration (ConversionViewModel.swift)
- `addToQueue()`: Validates settings and creates job(s)
- `addConcatenateJobsToQueue()`: Creates one job per fully selected group
- `addIndividualJobToQueue()`: Creates single job for selected clips
- `canAddToQueue`: Same validation as `canConvert`

### Files Created
- `Services/QueueManager.swift` - Queue management singleton
- `Views/QueueListView.swift` - Queue panel UI

### Files Modified
- `Models/P2Clip.swift` - Added `ConversionJob`, `JobStatus`
- `ConversionViewModel.swift` - Added queue integration methods
- `ContentView.swift` - Added queue panel, toggle button, "Add to Queue" button
