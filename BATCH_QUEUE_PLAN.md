# Plan: Multi-Card Batch Queue

## Objective
Enable users to queue multiple independent conversion tasks (e.g., merging several different P2 cards or processing multiple folders) and execute them in sequence. This decouples "Setting up a job" from "Executing a job."

---

## 1. Core Data Structures

### `ConversionJob` (Model)
A struct representing a single conversion task.
- `id: UUID`
- `cardName: String` (Source identifier)
- `clips: [P2Clip]` (The specific clips to process)
- `settings: ConversionSettings` (Format, mode, audio, TC, etc.)
- `destinationURL: URL` (The final output path)
- `status: JobStatus` (.pending, .active, .completed, .failed)
- `progress: Double` (0.0 to 1.0)
- `errorMessage: String?`

### `JobStatus` (Enum)
- `pending`: Waiting in queue.
- `preparing`: Gathering files/rewrapping.
- `active`: FFmpeg is processing.
- `completed`: Successfully finished.
- `failed`: Error encountered (with message).

---

## 2. Architecture: `QueueManager`

A central service (Singleton or EnvironmentObject) that manages the global state of conversions.

### Responsibilities
- **Queue Storage**: An array of `ConversionJob` objects.
- **Sequential Execution**: A loop that picks the next `pending` job and starts it.
- **Service Orchestration**: Communicates with `FFmpegWrapper` and `BMXWrapper`.
- **Global Progress**: Calculates overall progress (e.g., "3 of 5 jobs done").
- **Concurrency**: Only one "Heavy" conversion job (FFmpeg) runs at a time to prevent disk I/O bottlenecks.

---

## 3. UI Integration

### Main View Changes
- **"Add to Queue" Button**: Next to the "Convert" button. This validates settings and adds the current card/selection to the `QueueManager`.
- **Queue Sidebar/Panel**: A collapsible or separate view showing the list of jobs.

### Job Row UI
- Show source card name and destination filename.
- Progress bar for the active job.
- Status icons (Checkmark, Warning, Spinner).
- "Remove" button for pending/failed jobs.

---

## 4. Workflow

1.  **Load Card**: User selects a P2 card as they do now.
2.  **Configure**: User selects clips, output format, and filename.
3.  **Enqueue**: User clicks "Add to Queue". The UI clears or indicates success, allowing the user to load the *next* card immediately.
4.  **Process**: The `QueueManager` starts processing automatically (or when the user clicks a global "Start Queue" button).
5.  **Monitor**: User can see the progress of all cards in the queue while browsing a new card.

---

## 5. Technical Challenges

- **Security Scoped Resources**: macOS Sandbox/Permissions might require us to maintain access to multiple folders simultaneously. We need to ensure `startAccessingSecurityScopedResource()` is handled correctly for every item in the queue.
- **Resource Management**: Clearing temporary rewrap files for each job in the queue once it completes.
- **State Persistence**: If the app crashes or is closed, should the queue persist? (Phase 2 feature).

---

## Implementation Phases

1.  **Phase 1**: Define `ConversionJob` and create a basic `QueueManager`.
2.  **Phase 2**: Add "Add to Queue" logic to `ConversionViewModel`.
3.  **Phase 3**: Create a `QueueListView` to display the background tasks.
4.  **Phase 4**: Implement the execution loop in `QueueManager` (moving logic out of the local ViewModel).
5.  **Phase 5**: Add queue controls (Cancel All, Retry Failed, Clear Completed).
