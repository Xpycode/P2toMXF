# Decisions Log

This file tracks the WHY behind technical and design decisions.

---

## 2026-01-01 - BMX over Pure FFmpeg

**Context:** FFmpeg's MXF muxer fails with P2 AVC-Intra due to frame size padding mismatch (568320 vs 568832 bytes). P2 cameras use Panasonic's proprietary padding scheme.

**Options Considered:**
1. FFmpeg only - Would require patching FFmpeg source with Panasonic tables
2. BMX toolkit - Has manufacturer-specific lookup tables built-in
3. MOV output only - Works but limits NLE compatibility

**Decision:** Use BMX for OPAtom→OP1a rewrap, then FFmpeg for concatenation.

**Rationale:** BMX handles the padding correctly out of the box. Two-step pipeline is still fast (stream copy) and produces broadcast-compatible MXF.

**Consequences:** Need to bundle BMX binaries (~3MB) and fix dylib paths with install_name_tool.

---

## 2026-01-01 - Disable App Sandbox

**Context:** App needs to execute bundled binaries (ffmpeg, bmxtranswrap) and access user-selected directories.

**Options Considered:**
1. Keep sandbox, use XPC service - Complex, overkill for this use case
2. Disable sandbox - Simple, works, standard for media tools

**Decision:** Disable sandbox, keep Hardened Runtime for notarization.

**Rationale:** Media conversion tools commonly run without sandbox. Hardened Runtime provides enough security for distribution.

**Consequences:** Must sign bundled binaries with Hardened Runtime entitlements.

---

## 2026-01-01 - Run Script for lib/ Folder

**Context:** BMX dylibs need to be in bundle's Resources/lib/ folder, but adding to Xcode navigator caused linking errors (SIGABRT at launch).

**Options Considered:**
1. Add to project navigator - Caused Xcode to link dylibs incorrectly
2. Copy Bundle Resources phase - Didn't handle folder structure well
3. Run Script build phase - Full control over ditto command

**Decision:** Use Run Script phase with `ditto` to copy lib/ folder.

**Rationale:** Keeps dylibs out of Xcode's automatic linking while ensuring they're bundled correctly.

**Consequences:** Must set `ENABLE_USER_SCRIPT_SANDBOXING = NO` in build settings.

---

## 2026-01-01 - Timecode from Codec String, Not FrameRate Element

**Context:** P2 XML has both `<Codec>AVC-I_1080/25p</Codec>` and `<FrameRate>50p</FrameRate>`. These represent different things.

**Options Considered:**
1. Use FrameRate element - Gives wrong timecode calculations (50fps instead of 25fps)
2. Use Codec string - Correctly identifies timecode rate

**Decision:** Parse frame rate from Codec string, ignore FrameRate element for TC calculations.

**Rationale:** Codec string (e.g., "25p") is the timecode/playback rate. FrameRate element is sensor capture rate. TC operations need the playback rate.

**Consequences:** Added `frameRateFromCodec` flag to prevent FrameRate element from overwriting.

---

## 2026-01-01 - Queue Persistence via Codable + JSON

**Context:** Users may queue many jobs that take hours. If app crashes or restarts, queue should survive.

**Options Considered:**
1. No persistence - Queue lost on restart
2. UserDefaults - Size limits, not ideal for complex data
3. JSON file in Application Support - Simple, inspectable, unlimited size
4. Core Data - Overkill for simple list

**Decision:** JSON file at `~/Library/Application Support/P2toMXF/queue.json`

**Rationale:** Easy to debug, backup, and doesn't require Core Data complexity.

**Consequences:** All models need `Codable` conformance. URLs stored as strings.

---

## 2026-01-01 - Security-Scoped Bookmarks for Persistence

**Context:** Queued jobs reference user-selected directories. After app restart, sandbox (if ever re-enabled) would block access.

**Options Considered:**
1. Re-prompt user for access - Poor UX
2. Security-scoped bookmarks - Standard Apple solution

**Decision:** Create security-scoped bookmarks for card paths and output directories.

**Rationale:** Bookmarks persist across app launches and provide proper security model.

**Consequences:** Must call `startAccessingSecurityScopedResource()` and balance with `stopAccessingSecurityScopedResource()`. Bookmark resolution is separate from file path storage.

---

## 2026-01-04 - Separate Thumbnail View to Prevent Jitter

**Context:** During conversion, progress bar updates caused entire ClipRowView to re-render, making thumbnails jitter.

**Options Considered:**
1. Optimize with Equatable - Still causes re-render
2. Extract thumbnails to separate view - SwiftUI only re-renders changed views

**Decision:** Extract `ClipThumbnailsView` and `ClipStatusBadge` as isolated child views.

**Rationale:** SwiftUI's diffing is view-boundary based. Stable child views with unchanging inputs won't re-render.

**Consequences:** More view files, but better performance and cleaner separation.

---
*Add decisions as they are made. Future-you will thank present-you.*
