# Consolidated Fix Plan Summary (2026-01-03)

## Quick Reference: 21 Issues Across 4 Phases

### Phase 1: Critical (5 issues, 2-3 days)
1. **Silent XML parsing** - `P2CardParser.swift:54` - Use do/try/catch, surface errors
2. **Semaphore deadlock** - `ThumbnailManager.swift:149` - Add `defer { releaseSemaphore() }`
3. **isCancelling race** - `FFmpegWrapper.swift:49` - Use NSLock or OSAllocatedUnfairLock
4. **Security bookmarks** - `QueueManager.swift` - Store/resolve bookmark data
5. **Audio mapping ignored** - `FFmpegWrapper.swift:230` - Implement audio filter chains

### Phase 2: High (7 issues, 3-4 days)
6. Individual output overwrites - Add per-clip conflict resolution
7. MainActor singleton gap - Add @MainActor to static shared
8. File handle handlers persist - Clear in catch block
9. Security scope imbalance - Track accessed URLs in Set
10. Concat paths not escaped - Escape single quotes
11. @unchecked Sendable undocumented - Add threading contract comments
12. Slow-speed warning dead - Call SpeedTracker.checkSpeed() from progress

### Phase 3: Medium (5 issues, 2-3 days)
13. Excessive UI updates - Throttle to 10/sec
14. Synchronous queue persistence - Move to background Task
15. Unbounded thumbnail cache - Implement LRU with 100 cap
16. Container validation stub - Throw error or implement parsing
17. Duplicated tool resolution - Extract BundledToolResolver

### Phase 4: Low (4 issues, 1-2 days)
18. Large View files - Split ContentView and QueueListView
19. Inconsistent MARK style - Standardize on `// MARK: -`
20. Missing property docs - Add /// to computed properties
21. No test suite - Create test targets

## Key Files by Issue Count
| File | Issues |
|------|--------|
| FFmpegWrapper.swift | 5 |
| QueueManager.swift | 4 |
| ThumbnailManager.swift | 2 |
| P2CardParser.swift | 1 |
| BMXWrapper.swift | 2 |
| VerificationService.swift | 2 |

## All Three Reviews Agreed On
- Security-scoped bookmark persistence is broken
- Silent failures hide problems from users

## Full Plan Location
See: `CONSOLIDATED-FIX-PLAN.md` in project root
