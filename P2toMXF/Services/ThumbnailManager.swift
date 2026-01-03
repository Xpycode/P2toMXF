import Foundation
import AppKit

/// Manages asynchronous thumbnail generation for P2 clips with caching and concurrency control
actor ThumbnailManager {

    /// Thumbnail pair for a clip (first and last frames)
    struct ClipThumbnails: Sendable {
        let first: NSImage?
        let last: NSImage?

        static let empty = ClipThumbnails(first: nil, last: nil)
    }

    /// Source used for thumbnail extraction (for debugging/UI indication)
    enum ThumbnailSource: Sendable {
        case proxy      // PROXY MP4 - fast, good quality
        case mxf        // VIDEO MXF - slow, full quality
        case icon       // ICON BMP - instant, low quality (first frame only)
        case none       // No source available
    }

    // MARK: - Properties

    private let ffmpeg: FFmpegWrapper
    private var cache: [UUID: ClipThumbnails] = [:]
    private var pendingTasks: [UUID: Task<ClipThumbnails, Never>] = [:]

    /// Semaphore to limit concurrent FFmpeg processes
    private let maxConcurrentExtractions = 3
    private var activeExtractions = 0
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    init(ffmpeg: FFmpegWrapper = FFmpegWrapper()) {
        self.ffmpeg = ffmpeg
    }

    // MARK: - Public API

    /// Request thumbnails for a clip. Returns cached result or starts extraction.
    /// - Parameter clip: The P2 clip to get thumbnails for
    /// - Returns: ClipThumbnails with first and last frame images
    func getThumbnails(for clip: P2Clip) async -> ClipThumbnails {
        // Return cached result if available
        if let cached = cache[clip.id] {
            return cached
        }

        // Return result from pending task if already in progress
        if let pendingTask = pendingTasks[clip.id] {
            return await pendingTask.value
        }

        // Start new extraction task
        let task = Task {
            await extractThumbnails(for: clip)
        }
        pendingTasks[clip.id] = task

        let result = await task.value
        pendingTasks[clip.id] = nil
        cache[clip.id] = result

        return result
    }

    /// Cancel pending thumbnail extraction for a clip (e.g., when row scrolls off screen)
    func cancelRequest(for clipId: UUID) {
        pendingTasks[clipId]?.cancel()
        pendingTasks[clipId] = nil
    }

    /// Clear all cached thumbnails (e.g., when loading a new P2 card)
    func clearCache() {
        cache.removeAll()
        for task in pendingTasks.values {
            task.cancel()
        }
        pendingTasks.removeAll()
    }

    /// Check if thumbnails are cached for a clip
    func hasCachedThumbnails(for clipId: UUID) -> Bool {
        cache[clipId] != nil
    }

    // MARK: - Private Extraction Logic

    /// Extract both first and last frame thumbnails for a clip
    private func extractThumbnails(for clip: P2Clip) async -> ClipThumbnails {
        // Extract first and last frames concurrently
        async let firstFrame = extractFirstFrame(for: clip)
        async let lastFrame = extractLastFrame(for: clip)

        return ClipThumbnails(
            first: await firstFrame,
            last: await lastFrame
        )
    }

    /// Extract first frame with fallback chain: PROXY → ICON → MXF
    private func extractFirstFrame(for clip: P2Clip) async -> NSImage? {
        // 1. Try PROXY (fast, good quality)
        if let proxyURL = clip.proxyFile {
            if let image = await extractFrameWithSemaphore(from: proxyURL, atSeconds: 0) {
                return image
            }
        }

        // 2. Try ICON BMP (instant, low quality) - read directly, no FFmpeg needed
        if let iconURL = clip.iconFile,
           let image = NSImage(contentsOf: iconURL) {
            return image
        }

        // 3. Try VIDEO MXF (slow, full quality)
        if let videoURL = clip.videoFiles.first {
            if let image = await extractFrameWithSemaphore(from: videoURL, atSeconds: 0) {
                return image
            }
        }

        return nil
    }

    /// Extract last frame with fallback chain: PROXY → MXF (no ICON - it's first frame only)
    private func extractLastFrame(for clip: P2Clip) async -> NSImage? {
        let lastTime = clip.lastFrameTimestamp

        // 1. Try PROXY (fast, good quality)
        if let proxyURL = clip.proxyFile {
            if let image = await extractFrameWithSemaphore(from: proxyURL, atSeconds: lastTime) {
                return image
            }
        }

        // 2. Try VIDEO MXF (slow, full quality) - no ICON fallback for last frame
        if let videoURL = clip.videoFiles.first {
            if let image = await extractFrameWithSemaphore(from: videoURL, atSeconds: lastTime) {
                return image
            }
        }

        return nil
    }

    /// Extract a frame with semaphore-controlled concurrency
    private func extractFrameWithSemaphore(from url: URL, atSeconds timestamp: Double) async -> NSImage? {
        // Wait for semaphore slot
        await acquireSemaphore()
        defer { releaseSemaphore() }  // ALWAYS release, even on cancellation or error

        // Check for cancellation before starting expensive operation
        guard !Task.isCancelled else { return nil }

        return await ffmpeg.extractFrame(from: url, atSeconds: timestamp)
    }

    // MARK: - Semaphore Implementation

    private func acquireSemaphore() async {
        if activeExtractions < maxConcurrentExtractions {
            activeExtractions += 1
            return
        }

        // Wait until a slot is available
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    private func releaseSemaphore() {
        if let waiting = waitingContinuations.first {
            waitingContinuations.removeFirst()
            waiting.resume()
        } else {
            activeExtractions -= 1
        }
    }
}
