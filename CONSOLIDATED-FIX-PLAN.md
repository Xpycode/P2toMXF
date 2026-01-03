# P2toMXF Consolidated Fix Plan

**Created:** 2026-01-03
**Sources:** 3 code reviews (Anonymous, Gemini, Claude) + Jan 2nd memory
**Total Issues:** 21 unique issues across 4 severity levels

---

## Executive Summary

This document consolidates findings from three independent code reviews conducted on 2026-01-03, plus a prior review from 2026-01-02. Issues are deduplicated, prioritized, and organized into 4 implementation phases.

| Phase | Priority | Issues | Est. Effort |
|-------|----------|--------|-------------|
| 1 | Critical | 5 | 2-3 days |
| 2 | High | 7 | 3-4 days |
| 3 | Medium | 5 | 2-3 days |
| 4 | Low | 4 | 1-2 days |

**Recommended approach:** Complete Phase 1 before release. Phase 2 should follow shortly after. Phases 3-4 are technical debt to address over time.

---

## Phase 1: Critical Issues (Release Blockers)

### 1.1 Silent XML Parsing Failures
**Severity:** Critical | **Effort:** Low | **File:** `P2CardParser.swift:54`

**Problem:** `try?` silently swallows errors when parsing clip XML files. Users may be missing clips without any indication.

**Current Code:**
```swift
for xmlFile in xmlFiles {
    if let clip = try? parseClipXML(at: xmlFile, contentsPath: contentsPath) {
        clips.append(clip)
    }
}
```

**Fix:**
```swift
var clips: [P2Clip] = []
var parseErrors: [(file: URL, error: Error)] = []

for xmlFile in xmlFiles {
    do {
        let clip = try parseClipXML(at: xmlFile, contentsPath: contentsPath)
        clips.append(clip)
    } catch {
        parseErrors.append((xmlFile, error))
        print("[P2CardParser] Failed to parse \(xmlFile.lastPathComponent): \(error)")
    }
}

// Return errors alongside clips for UI display
return P2ParseResult(clips: clips, errors: parseErrors)
```

**Testing:** Create a malformed XML file in test P2 card and verify error is surfaced.

---

### 1.2 ThumbnailManager Semaphore Deadlock
**Severity:** Critical | **Effort:** Low | **File:** `ThumbnailManager.swift:149-162`

**Problem:** If a task is cancelled after acquiring semaphore but before releasing, waiting tasks hang forever.

**Current Code:**
```swift
private func extractFrameWithSemaphore(from url: URL, atSeconds timestamp: Double) async -> NSImage? {
    await acquireSemaphore()

    if Task.isCancelled {
        releaseSemaphore()
        return nil
    }

    let result = await ffmpeg.extractFrame(from: url, atSeconds: timestamp)
    releaseSemaphore()  // Not called if extractFrame throws or is cancelled mid-execution
    return result
}
```

**Fix:**
```swift
private func extractFrameWithSemaphore(from url: URL, atSeconds timestamp: Double) async -> NSImage? {
    await acquireSemaphore()
    defer { releaseSemaphore() }  // ALWAYS release

    guard !Task.isCancelled else { return nil }

    return await ffmpeg.extractFrame(from: url, atSeconds: timestamp)
}
```

**Testing:** Rapidly navigate between cards while thumbnails are loading. Verify no hangs.

---

### 1.3 Cancellation Flag Race Condition
**Severity:** Critical | **Effort:** Low | **File:** `FFmpegWrapper.swift:49, 582, 625, 647`

**Problem:** `isCancelling` is a plain Bool accessed from multiple threads without synchronization.

**Current Code:**
```swift
private var isCancelling = false  // Line 49

func cancelConversion() {
    isCancelling = true  // Line 625, called from main thread
}

// In terminationHandler (arbitrary thread):
let wasCancelled = self?.isCancelling ?? false  // Line 582
```

**Fix - Option A (NSLock):**
```swift
private let cancelLock = NSLock()
private var _isCancelling = false

private var isCancelling: Bool {
    get { cancelLock.withLock { _isCancelling } }
    set { cancelLock.withLock { _isCancelling = newValue } }
}
```

**Fix - Option B (OSAllocatedUnfairLock, macOS 13+):**
```swift
private let isCancellingLock = OSAllocatedUnfairLock(initialState: false)

var isCancelling: Bool {
    get { isCancellingLock.withLock { $0 } }
    set { isCancellingLock.withLock { $0 = newValue } }
}
```

**Testing:** Start long conversion, cancel repeatedly, verify correct status reported.

---

### 1.4 Security-Scoped Bookmarks Not Persisted
**Severity:** Critical | **Effort:** Medium | **Files:** `P2Clip.swift`, `QueueManager.swift`, `ContentView.swift`

**Problem:** Queue jobs save file paths as strings. After app restart, security-scoped access is lost and jobs fail.

**Current Flow:**
1. User selects P2 card folder via NSOpenPanel
2. `startAccessingSecurityScopedResource()` called
3. Job added to queue with path string
4. App quits/crashes
5. On relaunch, path string loaded but NO security scope

**Fix:**

1. **Add bookmark storage to ConversionJob:**
```swift
struct ConversionJob: Identifiable, Codable {
    // Existing properties...

    // Add bookmark data for security-scoped access
    var cardBookmarkData: Data?
    var outputBookmarkData: Data?

    // Resolve bookmark to URL with security scope
    func resolveCardURL() -> URL? {
        guard let data = cardBookmarkData else { return URL(fileURLWithPath: cardPathString) }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            // Regenerate bookmark
        }
        return url
    }
}
```

2. **Create bookmark when adding job:**
```swift
func addJob(_ job: ConversionJob, autoStart: Bool = false) {
    var mutableJob = job

    // Create security-scoped bookmark
    if let bookmarkData = try? job.cardPath.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    ) {
        mutableJob.cardBookmarkData = bookmarkData
    }

    // Same for output directory...

    jobs.append(mutableJob)
}
```

3. **Resolve bookmarks on queue load:**
```swift
private func loadQueue() {
    // After decoding jobs...
    for (index, job) in jobs.enumerated() {
        if let url = job.resolveCardURL() {
            jobs[index].cardPath = url
        } else {
            jobs[index].status = .failed("Cannot access source folder")
        }
    }
}
```

**Testing:** Add jobs to queue, force-quit app, relaunch, verify jobs can access files.

---

### 1.5 Audio Mapping & Timecode Settings Ignored
**Severity:** Critical | **Effort:** Medium | **Files:** `FFmpegWrapper.swift`, `BMXWrapper.swift`

**Problem:** The UI offers audio mapping options (All Channels, Stereo Mix, Mono) but the conversion always uses `-c:a copy`.

**Evidence (FFmpegWrapper.swift:230):**
```swift
// Stream copy (no re-encoding)
args.append(contentsOf: ["-c:v", "copy", "-c:a", "copy"])  // Always copy, ignores audioMapping
```

**Fix:**

1. **Update rewrapClipWithFFmpeg:**
```swift
// Audio mapping based on settings
switch settings.audioMapping {
case .allChannels:
    args.append(contentsOf: ["-c:a", "copy"])
    for i in 0..<clip.audioFiles.count {
        args.append(contentsOf: ["-map", "\(i + 1):a:0"])
    }

case .stereoMix:
    // Mix 4 mono channels to stereo
    args.append(contentsOf: [
        "-filter_complex", "[1:a][2:a][3:a][4:a]amerge=inputs=4,pan=stereo|c0=c0+c2|c1=c1+c3[aout]",
        "-map", "0:v:0",
        "-map", "[aout]",
        "-c:a", "aac", "-b:a", "256k"  // Re-encode for mix
    ])

case .mono:
    // Mix all to mono
    args.append(contentsOf: [
        "-filter_complex", "[1:a][2:a][3:a][4:a]amerge=inputs=4,pan=mono|c0=c0+c1+c2+c3[aout]",
        "-map", "0:v:0",
        "-map", "[aout]",
        "-c:a", "aac", "-b:a", "128k"
    ])
}
```

2. **Document BMX limitations:**
   - BMX's `bmxtranswrap` does NOT support audio remapping
   - If user selects Stereo Mix + MXF output, either:
     - a) Fall back to FFmpeg (loses MXF index table benefits)
     - b) Show UI warning that audio mapping requires MOV output
     - c) Use BMX for rewrap, then FFmpeg for audio remix

**UI Change (ContentView.swift):**
```swift
if settings.audioMapping != .allChannels && settings.outputContainer == .mxf {
    Text("Audio mixing requires MOV format")
        .foregroundColor(.orange)
        .font(.caption)
}
```

**Testing:** Convert with each audio mapping option, verify output channels match selection.

---

## Phase 2: High Priority Issues

### 2.1 Individual Outputs Can Overwrite Files
**File:** `QueueManager.swift:510-520`
**Effort:** Low

Add per-clip conflict resolution using existing `resolveFilenameConflict` method:
```swift
for clip in job.clips {
    var clipOutputURL = outputDir.appendingPathComponent("\(clip.displayName).\(ext)")
    clipOutputURL = resolveFilenameConflict(for: clipOutputURL)
    // ... process clip
}
```

---

### 2.2 MainActor Singleton Access Gap
**File:** `QueueManager.swift:9`
**Effort:** Low

Change:
```swift
static let shared = QueueManager()
```
To:
```swift
@MainActor static let shared = QueueManager()
```

---

### 2.3 File Handle Handlers Persist After Process Death
**Files:** `FFmpegWrapper.swift:516`, `BMXWrapper.swift:199`
**Effort:** Low

Add cleanup in catch block after `process.run()`:
```swift
do {
    try process.run()
} catch {
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    throw error
}
```

---

### 2.4 Security-Scoped Start/Stop Imbalance
**File:** `QueueManager.swift`
**Effort:** Medium

Track accessed resources to prevent nested start/stop:
```swift
private var accessedResources: Set<URL> = []

private func startAccessingIfNeeded(_ url: URL) -> Bool {
    guard !accessedResources.contains(url) else { return true }
    if url.startAccessingSecurityScopedResource() {
        accessedResources.insert(url)
        return true
    }
    return false
}

private func stopAccessingAll() {
    accessedResources.forEach { $0.stopAccessingSecurityScopedResource() }
    accessedResources.removeAll()
}
```

---

### 2.5 Concat Paths Not Escaped for Apostrophes
**File:** `FFmpegWrapper.swift:358-363`
**Effort:** Low

Escape single quotes in concat file list:
```swift
let escapedPath = file.path.replacingOccurrences(of: "'", with: "'\\''")
concatContent += "file '\(escapedPath)'\n"
```

---

### 2.6 @unchecked Sendable Without Documentation
**Files:** `FFmpegWrapper.swift:469-484`, `BMXWrapper.swift:155-170`, `VerificationService.swift:443-447`
**Effort:** Low

Add documentation explaining thread-safety contract:
```swift
/// Thread-safe output collector using NSLock.
///
/// THREADING CONTRACT:
/// - `append(_:)` and `output` are synchronized via `lock`
/// - Safe to call from any thread/queue
/// - DO NOT add properties without updating lock usage
private final class OutputCollector: @unchecked Sendable {
    // ...
}
```

---

### 2.7 Slow-Speed Warning Never Triggered
**Files:** `QueueManager.swift`, `SpeedTracker.swift`
**Effort:** Medium

The `slowSpeedWarning` property is only cleared, never set. `SpeedTracker.checkSpeed()` exists but is never called.

**Fix:** Call `checkSpeed` from progress callbacks:
```swift
// In processJob, inside progress handler:
if let metrics = metricsHandler?(progressValue, statusMessage) {
    let currentSpeed = metrics.speedMultiplier
    if let warning = speedTracker.checkSpeed(
        currentSpeed: currentSpeed,
        expectedSpeed: currentJobEstimate?.speedMultiplier ?? 30.0,
        remainingBytes: remainingBytes
    ) {
        await MainActor.run { slowSpeedWarning = warning }
    }
}
```

---

## Phase 3: Medium Priority Issues

### 3.1 Excessive UI Updates During Conversion
**File:** `FFmpegWrapper.swift:558-573`
**Effort:** Low

Throttle progress updates to 10/second:
```swift
private var lastProgressUpdate = Date.distantPast

// In handler:
let now = Date()
guard now.timeIntervalSince(lastProgressUpdate) > 0.1 else { return }
lastProgressUpdate = now
DispatchQueue.main.async { progress(...) }
```

---

### 3.2 Synchronous Queue Persistence
**File:** `QueueManager.swift:111-122`
**Effort:** Low

Move JSON encoding to background:
```swift
private func saveQueue() {
    let jobsToSave = self.jobs
    Task.detached(priority: .background) {
        let data = try? JSONEncoder().encode(jobsToSave)
        try? data?.write(to: Self.queueFileURL, options: .atomic)
    }
}
```

---

### 3.3 Unbounded Thumbnail Cache
**File:** `ThumbnailManager.swift:25`
**Effort:** Medium

Implement LRU eviction:
```swift
private let maxCacheSize = 100
private var accessOrder: [UUID] = []

// In getThumbnails:
accessOrder.removeAll { $0 == clip.id }
accessOrder.append(clip.id)

while cache.count > maxCacheSize, let oldest = accessOrder.first {
    accessOrder.removeFirst()
    cache.removeValue(forKey: oldest)
}
```

---

### 3.4 Container Validation Fallback Stub
**File:** `VerificationService.swift:242-267`
**Effort:** Medium

Either implement proper stderr parsing or return verification failure:
```swift
private func getContainerInfoWithFFmpeg(...) async throws -> ContainerInfo {
    // If we can't get real data, don't pretend we can verify
    throw VerificationError.ffprobeRequired
}
```

---

### 3.5 Duplicated Tool Path Resolution
**Files:** `FFmpegWrapper.swift:53-71`, `VerificationService.swift:44-69`
**Effort:** Low

Extract to shared utility:
```swift
// New file: Services/BundledToolResolver.swift
enum BundledTool: String {
    case ffmpeg, ffprobe, bmxtranswrap, mxf2raw
}

struct BundledToolResolver {
    static func path(for tool: BundledTool) -> URL? {
        if let bundled = Bundle.main.url(forResource: tool.rawValue, withExtension: nil) {
            return bundled
        }
        // Homebrew fallbacks...
    }
}
```

---

## Phase 4: Low Priority Issues

### 4.1 Large View Files
**Files:** `ContentView.swift` (768 lines), `QueueListView.swift` (491 lines)
**Effort:** Medium

Split into focused components:
- `ContentView` → `HeaderView`, `ClipTableView`, `FooterControlsView`
- `QueueListView` → `JobRowView`, `VerificationBadge`, `QueueControlsView`

---

### 4.2 Inconsistent MARK Comment Style
**All files**
**Effort:** Low

Standardize on `// MARK: - Section Name` for Xcode navigation.

---

### 4.3 Missing Public Property Documentation
**File:** `P2Clip.swift`
**Effort:** Low

Add `///` documentation to computed properties:
```swift
/// Total size of all video and audio files in bytes
var totalFileSize: Int64 { ... }
```

---

### 4.4 No Test Suite
**Effort:** High (ongoing)

Create test targets with focus on:
1. `Timecode` parsing and arithmetic
2. `P2XMLParser` with sample XML files
3. `SpeedTracker` estimation algorithms

---

## Dependencies & Order

```
Phase 1: All issues are independent, can be done in parallel

Phase 2:
  2.1 depends on 1.4 (uses same conflict resolution)
  2.7 requires understanding 1.5 flow

Phase 3:
  3.5 should be done before 3.4 (tool resolution needed for verification)

Phase 4:
  4.1 benefits from completing all Phase 1-3 file changes first
```

---

## Testing Checklist

After all fixes:

- [ ] Load P2 card with 1+ malformed XML files → error visible in UI
- [ ] Rapidly load/unload cards → no hanging or memory growth
- [ ] Cancel conversion mid-process → correct status, no zombie processes
- [ ] Add jobs to queue → quit app → relaunch → jobs can access files
- [ ] Convert with Stereo Mix → output has 2 channels
- [ ] Queue 2 jobs with same output name → second gets `(1)` suffix
- [ ] Convert large job → slow speed warning appears if applicable
- [ ] Convert via network drive → appropriate warnings shown

---

## Review Acknowledgments

This plan consolidates findings from:
1. **Anonymous Reviewer** (2026-01-03 10:00:18) - 7 issues, focus on feature gaps
2. **Gemini Agent** (2026-01-03 10:02:30) - Grade A-, focus on architecture
3. **Claude Code Opus 4.5** (2026-01-03 10:03:57) - 23 issues, focus on concurrency
4. **Prior Review Memory** (2026-01-02) - Initial analysis

All three reviews independently identified the security-scoped bookmark issue as a major concern.
