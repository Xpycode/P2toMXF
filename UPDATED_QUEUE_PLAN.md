# Plan: Enhanced Batch Queue (Manual Start & Robustness)

## Objective
Refine the Batch Queue to give users control over execution (Manual Start), ensure reliability (Sleep Prevention), and improve UX (Context-aware buttons).

---

## 1. Execution Control

### Disable Auto-Start
- **Change**: `QueueManager.addJob` should *not* call `processQueue()` automatically.
- **New State**: Queue enters a `paused` or `idle` state even with pending jobs.

### Context-Aware Action Button (Footer)
The main action button in `ContentView` will dynamically change:

| Queue State | Selection | Button Label | Action |
| :--- | :--- | :--- | :--- |
| Empty | Clips Selected | "Merge/Convert" | Immediate local conversion (Legacy) |
| **Has Items** | (Any) | **"Start Queue (N Jobs)"** | Starts `QueueManager` processing |
| Processing | (Any) | **"Pause/Cancel Queue"** | Pauses execution |

*Decision*: Should "Immediate Conversion" bypass the queue?
*Recommendation*: **Unify everything.** "Merge" simply adds to queue and immediately starts it. This simplifies the architecture to a single execution path.

---

## 2. System Reliability & Persistence

### Queue Persistence (JSON)
- **Feature**: Save the queue state to disk so it survives app restarts/crashes.
- **Implementation**: 
    - Conforms `ConversionJob` to `Codable`.
    - `QueueManager` saves `jobs` to `~/Library/Application Support/P2toMXF/queue.json` on every change.
    - Loads this file on app launch.

### Filename Conflicts (Auto-Rename)
- **Problem**: User queues Card A -> "Output.mxf", then Card B -> "Output.mxf".
- **Solution**: **Auto-Rename**
    - When `addJob` is called, check the `destinationURL` against all *pending* jobs.
    - If a conflict exists, append a counter: `Output.mxf` -> `Output (1).mxf`.
    - Update the job's settings to reflect this new path.

### Job History
- **Behavior**: Completed jobs **stay** in the list for verification.
- **UI**: Add a "Clear Completed" button to the Queue header/footer to remove them in bulk.

### Sleep Prevention (Optional)
- **Low Priority**: Can be handled by external apps (Amphetamine/Caffeine), but built-in `IOPMAssertionCreateWithName` is cleaner if time permits.

---

## 3. Queue UI Enhancements

### Queue Drawer / Sidebar
- A collapsible view showing the list of jobs.
- **Job Row**:
    - Source: "Card A (15 clips)"
    - Dest: "Project_Final.mxf"
    - Status: Icon (Pending, Active, Done) + Progress Bar.
    - Action: "X" to remove (if pending).

### Job History
- Completed jobs remain in the list (green checkmark).
- "Clear Finished" button to remove them.

---

## 4. Refined Architecture (Unified Path)

1.  **User clicks "Merge"**:
    - Validates settings.
    - Creates `ConversionJob`.
    - Adds to `QueueManager`.
    - **Auto-starts** (for this specific "Single Action" workflow).

2.  **User clicks "Add to Queue"**:
    - Validates settings.
    - Creates `ConversionJob`.
    - Adds to `QueueManager`.
    - **Does NOT start**.
    - User loads next card.

3.  **User clicks "Start Queue"**:
    - Triggers `QueueManager` loop.

---

## Implementation Checklist

1.  **QueueManager Update**: 
    - Remove auto-start from `addJob`.
    - Add `preventSystemSleep()` logic.
    - Add `checkForFilenameConflict()` logic.
2.  **ViewModel Update**:
    - Add logic to determine button state ("Merge" vs "Start Queue").
3.  **UI Update**:
    - Implement the Queue List view (Sidebar/Drawer).
    - Update Footer button logic.
