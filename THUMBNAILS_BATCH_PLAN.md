# Plan: Thumbnails & Batch Processing

## Objective
Enhance the P2toMXF application with visual verification capabilities and a robust background task system. Users should see the first and last frames of each clip to verify order, and the app should handle these (and other tasks) using a non-blocking batch processing architecture.

---

## 1. Data Model Enhancements (`P2Clip.swift`)

### Thumbnail Storage
Update the `P2Clip` model to track thumbnails.
- `firstFrameURL: URL?`: Path to the extracted first frame image.
- `lastFrameURL: URL?`: Path to the extracted last frame image.
- `p2IconURL: URL?`: Path to the native P2 BMP icon (if available).

### Helper Methods
- Add logic to calculate the exact timestamp for the "last frame" based on clip duration and frame rate.

---

## 2. Thumbnail Generation Service (`ThumbnailGenerator.swift`)

A new service dedicated to extracting frames using FFmpeg.

### Extraction Logic
- **First Frame**: `-ss 00:00:00.000`
- **Last Frame**: `-ss [duration - 1/fps]` (Precise seek for efficiency)
- **Command**: `ffmpeg -ss [time] -i [input] -frames:v 1 -q:v 2 [output_path]`
- **Output**: Save as JPEGs in a temporary directory (`/tmp/P2toMXF/thumbnails/`).

### Resource Management
- Ensure temporary files are cleaned up when the card is closed or the app exits.

---

## 3. Batch Processing Architecture

### `JobManager` Service
A centralized system to manage background tasks.
- **Queue Management**: Use a priority queue or a simple FIFO list.
- **Concurrency Control**: 
    - **Thumbnails**: 4-6 concurrent processes (CPU intensive but short).
    - **Conversions**: 1-2 concurrent processes (Disk/IO intensive).
- **Swift Concurrency**: Utilize `TaskGroup` or `AsyncStream` to manage execution flow.

### Integration with ViewModel
- `loadP2Card` triggers the automatic enqueuing of thumbnail jobs.
- As jobs complete, the `P2Clip` instances in the `clips` array are updated, triggering SwiftUI view refreshes.

---

## 4. UI/UX Implementation (`ContentView.swift`)

### `ClipRowView` Layout
- Add two image slots to each row.
- **Size**: Approx 80x45px (16:9 aspect ratio).
- **States**: 
    - *Pending*: Empty box with subtle border.
    - *Loading*: Small activity indicator.
    - *Loaded*: The extracted frame.
    - *Failed*: Generic "broken image" or "film" icon.

### Progress Reporting
- Show a small progress indicator in the header while the "Batch Thumbnailing" is active.
- Allow users to start conversions even if thumbnails are still loading.

---

## 5. Performance Considerations

- **Lazy Loading**: If a card has hundreds of clips, only generate thumbnails for what's "coming up" or prioritze the visible area (though batching all is generally acceptable for P2 cards which rarely exceed 100 clips).
- **Caching**: Check if a thumbnail already exists in the temp directory before spawning an FFmpeg process.
- **Cancellation**: If a card is ejected or a new one is loaded, immediately cancel all pending thumbnail jobs.

---

## Implementation Phases

1.  **Phase 1**: Update `P2Clip` and `P2CardParser` to find native P2 icons.
2.  **Phase 2**: Implement `ThumbnailGenerator` and test single-frame extraction.
3.  **Phase 3**: Implement `JobManager` for concurrent thumbnail extraction.
4.  **Phase 4**: Update `ContentView` to show the images.
5.  **Phase 5**: Refactor individual conversions to use the same `JobManager`.
