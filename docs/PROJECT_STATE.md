# Project State

## Quick Facts
- **Project:** P2toMXF
- **Started:** 2026-01-01
- **Current Phase:** polish
- **Last Session:** 2026-01-05

## Current Focus
App is **working and feature-complete**. Successfully merges P2 card clips into single MXF/MOV files using BMX + FFmpeg pipeline.

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

## Remaining Ideas
- [ ] XML metadata copy option
- [ ] Better BMX progress parsing
- [ ] Large binary download script (FFmpeg is 59MB)

## Key Decisions Made
See [decisions.md](decisions.md) for full history.

## Blockers
None - app is working.

## Next Actions
1. [x] Notarization - Done, app distributed via GitHub
2. [ ] Evaluate moving FFmpeg to download script (59MB in repo)

---
*Updated automatically by Claude during sessions*
