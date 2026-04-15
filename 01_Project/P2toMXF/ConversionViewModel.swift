import Foundation
import SwiftUI

@MainActor
class ConversionViewModel: ObservableObject {
    // MARK: - Static Formatters
    /// Cached DateFormatter for log timestamps (creating formatters is expensive)
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - Services
    let parser = P2CardParser()
    let ffmpeg = FFmpegWrapper()
    let thumbnailManager: ThumbnailManager

    // MARK: - Security-Scoped Access Tracking
    /// URLs for which security-scoped access has been started
    /// Must be balanced with stopAccessingSecurityScopedResource() when done
    var accessedURLs: Set<URL> = []

    /// Parent folder URLs used to discover multiple cards
    /// Maps parent URL to the set of card IDs loaded from it
    /// Used to release parent access when all cards from it are removed
    var parentFolderToCards: [URL: Set<UUID>] = [:]

    /// Start security-scoped access for a URL and track it
    /// - Parameter url: The security-scoped URL to access
    /// - Returns: True if access was granted
    func startSecurityAccess(for url: URL) -> Bool {
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
            return true
        }
        return false
    }

    /// Stop security-scoped access for a specific URL
    /// - Parameter url: The URL to release access for
    func stopSecurityAccess(for url: URL) {
        if accessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.remove(url)
        }
    }

    /// Release all tracked security-scoped access
    /// Call when cleaning up resources (e.g., app termination)
    func releaseAllSecurityAccess() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }

    // State - Multiple cards support
    @Published var loadedCards: [P2Card] = []
    @Published var activeCardId: UUID?
    @Published var selectedClips: Set<UUID> = []
    @Published var conversionStatus: [UUID: ConversionStatus] = [:]
    @Published var settings = ConversionSettings()

    /// Currently active card for display and operations
    var activeCard: P2Card? {
        guard let id = activeCardId else { return loadedCards.first }
        return loadedCards.first { $0.id == id }
    }

    /// Backwards compatibility alias
    var p2Card: P2Card? { activeCard }

    @Published var isLoading = false
    @Published var isConverting = false
    @Published var isCancelled = false
    @Published var errorMessage: String?
    @Published var ffmpegVersion: String?

    // MARK: - Console Log (Array-Based for Efficiency)
    /// Console log lines - stored as array for efficient trimming
    private var consoleLines: [String] = []

    /// Maximum number of console lines to retain (prevents unbounded memory growth)
    private let maxConsoleLines = 5000

    /// Console log as single string for display
    var consoleLog: String {
        consoleLines.joined(separator: "\n")
    }

    /// Feedback message after adding to queue
    @Published var queueFeedback: String?

    /// Current progress metrics for active conversion
    @Published var progressMetrics = ProgressMetrics()

    var hasFFmpeg: Bool {
        ffmpeg.isFFmpegAvailable
    }

    func log(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        consoleLines.append(line)

        // Trim old lines if over limit (keep last maxConsoleLines)
        if consoleLines.count > maxConsoleLines {
            let excess = consoleLines.count - maxConsoleLines
            consoleLines.removeFirst(excess)
        }
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    // MARK: - Progress Metrics

    /// Initializes progress metrics for a new conversion.
    /// Elapsed time and remaining estimates are driven by `TimelineView` in the UI layer;
    /// no manual Timer is needed here.
    func initProgressMetrics(totalClips: Int) {
        progressMetrics = ProgressMetrics()
        progressMetrics.startTime = Date()
        progressMetrics.totalClips = totalClips
        progressMetrics.phase = "Starting..."
    }

    /// Updates progress metrics from FFmpeg callback
    func updateMetrics(_ metrics: ProgressMetrics) {
        // Preserve startTime from our timer
        var updated = metrics
        updated.startTime = progressMetrics.startTime
        updated.totalClips = progressMetrics.totalClips
        progressMetrics = updated
    }

    var selectedClipCount: Int {
        selectedClips.count
    }

    /// Effective output filename (considers useFolderNameAsFilename setting)
    var effectiveOutputFilename: String {
        if settings.useFolderNameAsFilename, let cardName = p2Card?.name {
            return cardName
        }
        return settings.outputFilename
    }

    var allClipsSelected: Bool {
        guard let card = p2Card else { return false }
        return selectedClips.count == card.clips.count
    }

    /// Clips sorted by timecode for processing
    var sortedSelectedClips: [P2Clip] {
        guard let card = p2Card else { return [] }
        return card.clips
            .filter { selectedClips.contains($0.id) }
            .sorted { $0.startTimecode < $1.startTimecode }
    }

    /// All clips sorted by timecode (for grouping)
    var sortedAllClips: [P2Clip] {
        guard let card = p2Card else { return [] }
        return card.clips.sorted { $0.startTimecode < $1.startTimecode }
    }

    init() {
        self.thumbnailManager = ThumbnailManager(ffmpeg: ffmpeg)
        Task {
            ffmpegVersion = await ffmpeg.getVersionInfo()
        }
    }

    // MARK: - Selection

    func toggleClipSelection(_ clip: P2Clip) {
        if selectedClips.contains(clip.id) {
            selectedClips.remove(clip.id)
        } else {
            selectedClips.insert(clip.id)
        }
    }

    func selectAllClips() {
        guard let card = p2Card else { return }
        selectedClips = Set(card.clips.map { $0.id })
    }

    func deselectAllClips() {
        selectedClips.removeAll()
    }
}
