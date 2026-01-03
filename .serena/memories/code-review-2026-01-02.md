# Code Review Findings - 2026-01-02

## Summary
Comprehensive code review completed. Overall grade: **B+** (Good with Notable Issues)

## Critical Issues to Address

### 1. Swift 6 Concurrency Violations
- **`@unchecked Sendable` in OutputCollector** - `FFmpegWrapper.swift:470-485` and `BMXWrapper.swift:155-170`
  - Uses `NSLock` but bypasses compiler checking
  - Consider migrating to actors or `OSAllocatedUnfairLock`

- **Non-Sendable capture in Process handlers** - `FFmpegWrapper.swift:516-576`
  - `FFmpegWrapper` not marked Sendable but captured in closures on arbitrary threads

- **MainActor singleton gaps** - `QueueManager.swift`
  - `static let shared` can be accessed from any context despite `@MainActor` annotation

### 2. Memory Leak Potential
- **Retain in file handle handlers** - `FFmpegWrapper.swift:516`, `BMXWrapper.swift:199`
  - Handlers may persist if process never terminates (zombie process)
  - Always set `readabilityHandler = nil` in cleanup, not just terminationHandler

- **Unbounded thumbnail cache** - `ThumbnailManager.swift:27-28`
  - Cache grows without limit; implement LRU with size caps

### 3. Error Handling Issues
- **Silent XML parsing failures** - `P2CardParser.swift:54`
  - `try?` swallows errors; users don't see when clips fail to load
  - Should collect and report parsing errors

## Medium Priority Issues

### Race Conditions
- **Cancellation flag race** - `FFmpegWrapper.swift:624-643`
  - `isCancelling` is plain Bool accessed from multiple threads
  - Use atomic operations or actor isolation

### Potential Deadlock
- **ThumbnailManager semaphore** - `ThumbnailManager.swift:166-186`
  - If tasks holding slots are cancelled without `releaseSemaphore()`, waiters block forever
  - Use `defer { releaseSemaphore() }` pattern

### Security-Scoped Resource Imbalance
- **QueueManager** - Multiple locations
  - Nested access to same card path can cause start/stop imbalance
  - Track accessed resources in a Set

### Performance
- **Excessive UI updates** - `FFmpegWrapper.swift:558-573`
  - Progress updates on every FFmpeg line (25-60/sec)
  - Throttle to 10 updates/sec max

- **Synchronous queue persistence** - `QueueManager.swift`
  - JSON encoding on main actor can cause UI hitches
  - Move to background task

## Code Quality Notes

### Large Files to Split
- `ContentView.swift` (440 lines) → HeaderView, ClipTableView, FooterControlsView
- `QueueListView.swift` (491 lines)

### Repeated Code
- FFmpeg/ffprobe path resolution duplicated in `FFmpegWrapper` and `VerificationService`
- Create shared `BundledToolResolver` utility

### Dead Code
- `VerificationService.swift:253-267` (`getContainerInfoWithFFmpeg`) - Returns placeholder data only

## What's Working Well
- Clean MVVM architecture with service layer
- `ThumbnailManager` correctly uses Swift actors
- Queue persistence with Codable survives app restart
- Comprehensive `CLAUDE.md` documentation
- Good use of `defer` for cleanup in most places
- Detailed progress metrics with speed/time estimates

## Files by Issue Count
| File | Issues | Priority |
|------|--------|----------|
| FFmpegWrapper.swift | 4 | High |
| QueueManager.swift | 3 | High |
| BMXWrapper.swift | 2 | Medium |
| ThumbnailManager.swift | 2 | Medium |
| VerificationService.swift | 2 | Low |
| P2CardParser.swift | 1 | High |
| ContentView.swift | 2 | Low |

## Next Steps
1. Fix silent XML parsing failures (user-facing bug)
2. Add `defer { releaseSemaphore() }` to ThumbnailManager
3. Throttle progress updates
4. Consider actor migration for process wrappers

## Full Report
See: `code-review--2026-01-02--13-45.md` in project root
