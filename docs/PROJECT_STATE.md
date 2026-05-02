# Project State

## Quick Facts
- **Project:** P2toMXF
- **Started:** 2026-01-01
- **Current Phase:** v1.3 planning
- **Version:** 1.2 (build 1200) — v1.3 in progress
- **Last Session:** 2026-04-15

## Current Focus
v1.3 "Polish & Distribution" scope confirmed: Sparkle auto-update, diagnostic logging, Theme migration for remaining chrome, FCPToolbarButtonStyle adoption, README / landing page from forum research. All reinforce App Shell Standard compliance and make the app distribution-ready.

## What It Does
macOS utility that converts Panasonic P2 card footage:
- Parses P2 XML metadata and discovers clips
- Rewraps OPAtom MXF files to OP1a using BMX toolkit
- Concatenates or exports individual clips via FFmpeg
- Preserves timecode, supports MXF/MOV output
- Multi-job queue with persistence, verification, time estimates

## Tech Stack
- **Platform:** macOS 14.0+, SwiftUI
- **Architecture:** MVVM (ContentView → ViewModel → Services)
- **External Tools:** FFmpeg 8.0.1, BMX toolkit (bundled)
- **Key Services:** P2CardParser, FFmpegWrapper, BMXWrapper, QueueManager, VerificationService, SpeedTracker

## Features Completed
- [x] P2 card parsing and clip discovery
- [x] BMX + FFmpeg merge pipeline
- [x] Concatenate or Individual export modes
- [x] MXF/MOV output format selection
- [x] Timecode continuity checking
- [x] Multi-job queue with persistence
- [x] Sleep prevention during conversion
- [x] Output file verification (Quick/Full)
- [x] Time estimation with speed tracking
- [x] Multi-card loading from parent folder
- [x] Cmd+O keyboard shortcut
- [x] Configurable temp folder (File → Temp Folder…) with preflight disk-space check
- [x] FCP-style dark theme (App Shell Standard) matching Penumbra/CropBatch
- [x] Reveal-in-Finder per completed job; richer failed-job UI with volume-named errors

## Remaining Ideas
- [ ] XML metadata copy option
- [ ] Better BMX progress parsing
- [ ] Large binary download script (FFmpeg is 59MB)
- [ ] P2 clip preview via proxy MP4s (Panasonic P2 Viewer broken on modern macOS)
- [ ] Improve README with forum research findings
- [x] Fix frozen 0:00 elapsed timer during queue processing (TimelineView refactor)
- [x] Disk-space safeguards: configurable temp folder, preflight check, enriched error messages

## Key Decisions Made
See [decisions.md](decisions.md) for full history.

## Blockers
None.

## Next Actions
1. [x] Notarization - Done, app distributed via GitHub
2. [x] Production review — 9 issues fixed (2026-04-13)
3. [x] File splitting — all files under 500 lines (2026-04-13)
4. [x] Disk-space safeguards + configurable temp folder (2026-04-14)
5. [x] FCP Theme + forced dark mode migration (2026-04-14)

### v1.3 "Polish & Distribution" — in progress
6. [ ] Sparkle auto-update integration (appcast, EdDSA signing, INFOPLIST_KEY gotcha)
7. [ ] Diagnostic logging (os.Logger subsystems + log export for bug reports)
8. [ ] Migrate remaining `Color.gray` / `.secondary` chrome → `Theme.*`
9. [ ] Adopt `FCPToolbarButtonStyle` for full App Shell Standard match
10. [ ] README / landing page copy from forum research

### Deferred to v1.4+
11. [ ] UI audit: empty/loading/error states
12. [ ] Evaluate moving FFmpeg to download script (59MB in repo)
13. [ ] P2 clip preview via proxy MP4s (Panasonic P2 Viewer broken on modern macOS)

---
*Updated automatically by Claude during sessions*
