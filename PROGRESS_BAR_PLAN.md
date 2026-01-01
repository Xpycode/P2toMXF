# Plan: Advanced Progress Bar & Cancellation Fixes

## Objective
Replace the generic spinner/progress bar with a detailed status display in the footer. Fix the cancellation logic to ensuring processes terminate cleanly.

---

## 1. UI Layout (Footer Integration)

### Current Layout
`[ ... settings ... ] [ Spacer ] [ Action Button ]`

### Proposed Layout (When Active)
Replace the *Action Button* area with a dedicated **Progress Control Panel**.

```text
[ ... settings (disabled) ... ] [ Spacer ] [ Progress Panel ] [ Cancel Button ]
```

### Progress Panel Detail
A compact stack or grid showing:
1.  **Main Bar**: Graphic progress (0-100%).
2.  **Status Text**: "Merging Clip 3/10..." or "Concatenating..."
3.  **Metrics Row** (Tiny font):
    `Elapsed: 00:15  |  Rem: 01:20  |  Speed: 240 fps (10x)`

---

## 2. Cancellation Logic Fixes

### Problem Diagnosis
The current `process.terminate()` might not be killing child processes (like `bmxtranswrap` or `ffmpeg`) if they are spawned via a shell or if the Swift `Process` object loses the handle.

### Solutions
1.  **Process Groups**: Ensure we kill the entire process group if we launched via shell.
2.  **Task Handling**: Ensure the Swift `Task` running the conversion loop checks for cancellation (`Task.checkCancellation()`) between steps (e.g., between rewrapping Clip A and Clip B).
3.  **FFmpeg specific**: Send `q` to stdin or `SIGTERM` explicitly.

### Implementation
- Update `FFmpegWrapper` to store the active `Process` robustly.
- Add a `cancellationHandler` to the async functions.
- In `mergeClips`, check `Task.isCancelled` inside the loop.

---

## 3. Metrics Calculation

### Data Sources
- **Time Elapsed**: Simple `Date()` delta since start.
- **Time Remaining**:
    - `(Elapsed / Progress) * (1 - Progress)`
    - Needs "Moving Average" to smooth out jumps.
- **Speed**:
    - Parse `speed=12.5x` or `fps=300` from FFmpeg stderr output.
    - For BMX (which has no progress output), use file size / time or clip count / time.

### ViewModel Integration
Add `@Published` properties to `ConversionViewModel` (or `Job` in the future):
- `startTime: Date?`
- `estimatedTimeRemaining: TimeInterval?`
- `currentSpeed: String?`

---

## 4. Batch Queue Compatibility

The UI component `ProgressControlPanel` should be reusable.
- **Single Mode**: Shows progress of the single active task.
- **Queue Mode**: The footer might show "Global Queue Progress," while the Queue View shows per-job details.

---

## Implementation Steps

1.  **Fix Cancellation**: Refactor `FFmpegWrapper` and `ConversionViewModel` to handle `Task` cancellation correctly immediately.
2.  **Metrics Parsing**: Update regex in `FFmpegWrapper` to capture `speed=`, `bitrate=`, `time=` from stderr.
3.  **Timer Loop**: Add a Timer in ViewModel to update "Elapsed Time" every second.
4.  **UI Construction**: Build the new footer layout with the detailed metrics row.
