# Session History

## Active Project
**P2toMXF** - macOS utility to convert Panasonic P2 card footage to MXF/MOV

## Current Status
→ See [PROJECT_STATE.md](../PROJECT_STATE.md)

## Sessions

| Date | Focus | Outcome |
|------|-------|---------|
| 2026-01-01 | Initial Build | Discovered P2 MXF structure, built BMX+FFmpeg pipeline |
| 2026-01-01 | Refinements | Custom filenames, format selection, processing modes, TC checks |
| 2026-01-01 | UI Polish | Footer layout, app icon, About panel credits |
| 2026-01-01 | Batch Queue | Multi-job queue with sequential execution |
| 2026-01-01 | Enhanced Queue | Persistence, sleep prevention, conflict resolution |
| 2026-01-01 | Verification | Quick/Full decode verification for output files |
| 2026-01-01 | Time Estimation | Speed tracking, pre-conversion estimates, slow warnings |
| 2026-01-04 | Bug Fixes | Queue panel sizing, thumbnail jitter, verification fixes |
| 2026-01-04 | Display Fixes | Job name suffix bug, re-verify capability |
| 2026-01-05 | Multi-Card | Load multiple P2 cards from parent folder, Cmd+O shortcut |

**Note:** Detailed session logs are in [CLAUDE.md](../../../CLAUDE.md) under "Session Log" sections.

---

## Session Log Template

When starting a new session, create a file: `sessions/YYYY-MM-DD-[a|b|c].md`

```markdown
# Session: [Date] [a/b/c]

## Goal
[What we're trying to accomplish]

## Context
- Previous session: [link or summary]
- Current phase: [discovery|planning|implementation|polish|shipping]

## Progress

### Completed
- [x] [What got done]

### Discovered
- [New things learned]

### Decisions Made
- [Decision] → logged in decisions.md

## Next Session
- [What to do next]
```

---
*One log per session. Link from here.*
