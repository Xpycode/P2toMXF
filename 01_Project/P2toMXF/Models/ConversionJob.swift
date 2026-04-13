import Foundation

// MARK: - Batch Queue Models

/// Status of a conversion job in the queue
enum JobStatus: Equatable, Codable {
    case pending       // Waiting in queue
    case preparing     // Gathering files/rewrapping
    case active        // FFmpeg is processing
    case completed     // Successfully finished
    case failed(String) // Error encountered
    case cancelled     // User cancelled

    var displayName: String {
        switch self {
        case .pending: return "Queued"
        case .preparing: return "Preparing"
        case .active: return "Converting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .preparing: return "gearshape.2"
        case .active: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - Codable (custom for associated value)

    private enum CodingKeys: String, CodingKey {
        case type, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pending": self = .pending
        case "preparing": self = .preparing
        case "active": self = .active
        case "completed": self = .completed
        case "failed":
            let message = try container.decode(String.self, forKey: .errorMessage)
            self = .failed(message)
        case "cancelled": self = .cancelled
        default: self = .pending
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pending: try container.encode("pending", forKey: .type)
        case .preparing: try container.encode("preparing", forKey: .type)
        case .active: try container.encode("active", forKey: .type)
        case .completed: try container.encode("completed", forKey: .type)
        case .failed(let message):
            try container.encode("failed", forKey: .type)
            try container.encode(message, forKey: .errorMessage)
        case .cancelled: try container.encode("cancelled", forKey: .type)
        }
    }
}

/// A single conversion job in the queue
struct ConversionJob: Identifiable, Codable {
    let id: UUID
    let cardName: String          // Source P2 card name
    private var cardPathString: String  // For security-scoped access (stored as path)
    let clips: [P2Clip]           // Clips to process
    let settings: ConversionSettings
    private var destinationPathString: String  // Final output path (stored as path)
    let createdAt: Date

    var status: JobStatus = .pending
    var progress: Double = 0.0    // 0.0 to 1.0
    var startedAt: Date?          // When processing started (for elapsed time)

    // Security-scoped bookmark data for persisting file access across app launches
    var cardBookmarkData: Data?
    var outputBookmarkData: Data?

    // Verification state
    var verificationStatus: VerificationStatus = .unverified
    var verificationResult: VerificationResult?
    var verificationProgress: Double = 0.0  // 0.0 to 1.0

    // Actual output files created (may differ from expected due to conflict resolution)
    // Stored as path strings for Codable conformance
    private var actualOutputPathStrings: [String] = []

    /// URLs of actual output files created during conversion
    /// Use this for verification instead of re-deriving from clip names
    var actualOutputURLs: [URL] {
        get { actualOutputPathStrings.map { URL(fileURLWithPath: $0) } }
        set { actualOutputPathStrings = newValue.map { $0.path } }
    }

    /// Records an output file that was actually created during conversion
    mutating func recordOutputURL(_ url: URL) {
        actualOutputPathStrings.append(url.path)
    }

    // URL accessors
    var cardPath: URL {
        get { URL(fileURLWithPath: cardPathString) }
        set { cardPathString = newValue.path }
    }
    var destinationURL: URL {
        get { URL(fileURLWithPath: destinationPathString) }
        set { destinationPathString = newValue.path }
    }

    /// Resolves the card bookmark to a security-scoped URL
    /// - Returns: URL with security scope, or nil if bookmark is invalid/stale
    mutating func resolveCardBookmark() -> URL? {
        guard let data = cardBookmarkData else {
            return URL(fileURLWithPath: cardPathString)
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            // Try to regenerate bookmark with new URL
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                cardBookmarkData = newData
            }
        }
        cardPathString = url.path
        return url
    }

    /// Resolves the output bookmark to a security-scoped URL for the output directory
    /// - Returns: URL with security scope for the output directory, or the directory from destinationPathString
    /// - Note: This returns the directory URL for security-scoped access, NOT the file URL.
    ///   The destinationPathString (file path) is NOT modified by this method.
    mutating func resolveOutputBookmark() -> URL? {
        guard let data = outputBookmarkData else {
            // No bookmark data - return the parent directory of the destination file
            return URL(fileURLWithPath: destinationPathString).deletingLastPathComponent()
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            // Try to regenerate bookmark with new URL
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                outputBookmarkData = newData
            }
        }
        // Note: Do NOT update destinationPathString here!
        // The bookmark is for the OUTPUT DIRECTORY, not the file.
        // destinationPathString should preserve the full file path with filename.
        return url
    }

    /// Display name for the job (uses output filename)
    var displayName: String {
        if settings.processingMode == .individual {
            return "\(cardName) (\(clips.count) clips)"
        } else {
            // For concatenate mode, check if destinationURL is a proper file path
            let ext = settings.outputContainer.fileExtension
            let lastComponent = destinationURL.lastPathComponent

            // If it already has the correct extension, use it as-is
            if lastComponent.lowercased().hasSuffix(".\(ext)") {
                return lastComponent
            }

            // Old job format - destinationURL is a directory, construct filename
            let baseName: String
            if !settings.outputFilename.isEmpty {
                baseName = settings.outputFilename
            } else if settings.useFolderNameAsFilename {
                baseName = cardName
            } else {
                baseName = cardName
            }
            return "\(baseName).\(ext)"
        }
    }

    /// Expected output format
    var outputFormat: String {
        settings.outputContainer.rawValue
    }

    /// Total duration of all clips in frames
    var totalDurationFrames: Int {
        clips.reduce(0) { $0 + $1.durationFrames }
    }

    /// Human-readable duration
    var formattedDuration: String {
        guard let fps = clips.first?.frameRateDouble, fps > 0 else { return "--:--:--" }
        let tc = Timecode.from(frames: totalDurationFrames, frameRate: fps)
        return tc.description
    }

    init(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL,
        cardBookmarkData: Data? = nil,
        outputBookmarkData: Data? = nil
    ) {
        self.id = UUID()
        self.cardName = cardName
        self.cardPathString = cardPath.path
        self.clips = clips
        self.settings = settings
        self.destinationPathString = destinationURL.path
        self.createdAt = Date()
        self.cardBookmarkData = cardBookmarkData
        self.outputBookmarkData = outputBookmarkData
    }

    /// Creates a job with security-scoped bookmarks from the provided URLs
    /// - Note: Call this when the URLs have active security scope (e.g., from NSOpenPanel)
    static func withBookmarks(
        cardName: String,
        cardPath: URL,
        clips: [P2Clip],
        settings: ConversionSettings,
        destinationURL: URL
    ) -> ConversionJob {
        // Create security-scoped bookmarks while we have access
        let cardBookmark = try? cardPath.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Determine the correct directory for the output bookmark
        // - In individual mode, destinationURL IS the output directory
        // - In concatenate mode, destinationURL is the output file, so get its parent
        let outputDirectoryURL: URL
        if settings.processingMode == .individual {
            outputDirectoryURL = destinationURL
        } else {
            outputDirectoryURL = destinationURL.deletingLastPathComponent()
        }

        let outputBookmark = try? outputDirectoryURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return ConversionJob(
            cardName: cardName,
            cardPath: cardPath,
            clips: clips,
            settings: settings,
            destinationURL: destinationURL,
            cardBookmarkData: cardBookmark,
            outputBookmarkData: outputBookmark
        )
    }

    // Codable keys
    enum CodingKeys: String, CodingKey {
        case id, cardName, cardPathString, clips, settings
        case destinationPathString, createdAt, status, progress, startedAt
        case cardBookmarkData, outputBookmarkData
        case verificationStatus, verificationResult, verificationProgress
        case actualOutputPathStrings
    }
}
