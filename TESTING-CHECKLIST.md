# P2toMXF Testing Checklist

**Purpose:** Manual verification after code review fixes (2026-01-03)

---

## Pre-Release Tests

- [ ] **Malformed XML handling** - Load P2 card with 1+ malformed XML files → error visible in UI
- [ ] **No thumbnail hangs** - Rapidly load/unload cards → no hanging or memory growth
- [ ] **Cancel conversion** - Cancel mid-process → correct status, no zombie processes
- [ ] **Queue persistence** - Add jobs to queue → quit app → relaunch → jobs can access files
- [ ] **Stereo mix** - Convert with Stereo Mix audio → output has 2 channels
- [ ] **Filename conflicts** - Queue 2 jobs with same output name → second gets `(1)` suffix
- [ ] **Slow speed warning** - Convert large job → slow speed warning appears if applicable
- [ ] **Network drive** - Convert via network drive → appropriate warnings shown

---

## Quick Smoke Test

For routine builds, just verify:

- [ ] App launches without crash
- [ ] Can load test P2 card
- [ ] Can convert 1 clip to MOV
