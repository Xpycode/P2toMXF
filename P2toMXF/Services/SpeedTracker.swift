import Foundation

/// Tracks historical conversion speeds and provides time estimates
/// Persists speed records to disk for accurate predictions over time
@MainActor
class SpeedTracker: ObservableObject {
    // MARK: - Shared Instance
    static let shared = SpeedTracker()

    // MARK: - Published State
    @Published private(set) var records: [ConversionSpeedRecord] = []
    @Published private(set) var currentSpeedWarning: SlowSpeedWarning?

    // MARK: - Constants
    private static let maxRecords = 50  // Keep last 50 conversions
    private static let recordsFileName = "speed_records.json"

    /// Default speed multiplier when no history exists (conservative estimate)
    private static let defaultSpeedMultiplier = 15.0  // 15x realtime

    /// Threshold below which we warn about slow speed (as fraction of expected)
    private static let slowSpeedThreshold = 0.3  // Warn if < 30% of expected speed

    // MARK: - Persistence

    private var recordsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("P2toMXF", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent(Self.recordsFileName)
    }

    // MARK: - Init

    private init() {
        loadRecords()
    }

    // MARK: - Persistence Methods

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: recordsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: recordsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([ConversionSpeedRecord].self, from: data)
        } catch {
            print("Failed to load speed records: \(error)")
        }
    }

    private func saveRecords() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: recordsFileURL, options: .atomic)
        } catch {
            print("Failed to save speed records: \(error)")
        }
    }

    // MARK: - Record Tracking

    /// Records a completed conversion for future estimates
    func recordConversion(
        bytesProcessed: Int64,
        durationSeconds: TimeInterval,
        contentDurationSeconds: Double,
        processingMode: ConversionSettings.ProcessingMode,
        outputFormat: ConversionSettings.OutputContainer
    ) {
        guard durationSeconds > 0, contentDurationSeconds > 0 else { return }

        let speedMultiplier = contentDurationSeconds / durationSeconds

        let record = ConversionSpeedRecord(
            date: Date(),
            bytesProcessed: bytesProcessed,
            durationSeconds: durationSeconds,
            speedMultiplier: speedMultiplier,
            processingMode: processingMode,
            outputFormat: outputFormat
        )

        records.append(record)

        // Keep only recent records
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }

        saveRecords()
    }

    // MARK: - Estimation

    /// Generates a time estimate for a set of clips
    func estimateConversion(
        clips: [P2Clip],
        processingMode: ConversionSettings.ProcessingMode,
        outputFormat: ConversionSettings.OutputContainer
    ) -> ConversionEstimate {
        // Calculate totals
        let totalBytes = clips.reduce(Int64(0)) { $0 + $1.totalFileSize }
        let totalFrames = clips.reduce(0) { $0 + $1.durationFrames }
        let fps = clips.first?.frameRateDouble ?? 25.0
        let totalDurationSeconds = Double(totalFrames) / fps

        // Get speed estimate based on history
        let (speedMultiplier, confidence) = getSpeedEstimate(
            processingMode: processingMode,
            outputFormat: outputFormat
        )

        // Calculate estimated time
        let estimatedSeconds = totalDurationSeconds / speedMultiplier

        return ConversionEstimate(
            totalBytes: totalBytes,
            totalDurationSeconds: totalDurationSeconds,
            clipCount: clips.count,
            estimatedSeconds: estimatedSeconds,
            speedMultiplier: speedMultiplier,
            confidence: confidence
        )
    }

    /// Generates a time estimate for a job
    func estimateJob(_ job: ConversionJob) -> ConversionEstimate {
        return estimateConversion(
            clips: job.clips,
            processingMode: job.settings.processingMode,
            outputFormat: job.settings.outputContainer
        )
    }

    /// Gets the expected speed multiplier based on history
    private func getSpeedEstimate(
        processingMode: ConversionSettings.ProcessingMode,
        outputFormat: ConversionSettings.OutputContainer
    ) -> (speed: Double, confidence: EstimateConfidence) {
        // Filter records by matching mode/format from last 7 days
        let recentCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let matchingRecent = records.filter { record in
            record.date > recentCutoff &&
            record.processingMode == processingMode &&
            record.outputFormat == outputFormat
        }

        if matchingRecent.count >= 3 {
            // High confidence: recent matching records
            let avgSpeed = matchingRecent.map(\.speedMultiplier).reduce(0, +) / Double(matchingRecent.count)
            return (avgSpeed, .high)
        }

        // Fall back to all records with same mode/format
        let matchingAll = records.filter { record in
            record.processingMode == processingMode &&
            record.outputFormat == outputFormat
        }

        if !matchingAll.isEmpty {
            // Medium confidence: historical matching records
            let avgSpeed = matchingAll.map(\.speedMultiplier).reduce(0, +) / Double(matchingAll.count)
            return (avgSpeed, .medium)
        }

        // Fall back to any records
        if !records.isEmpty {
            let avgSpeed = records.map(\.speedMultiplier).reduce(0, +) / Double(records.count)
            return (avgSpeed, .medium)
        }

        // No history: use default
        return (Self.defaultSpeedMultiplier, .low)
    }

    // MARK: - Slow Speed Detection

    /// Checks if current speed is below expected and generates warning
    func checkSpeed(
        currentSpeedMultiplier: Double,
        bytesRemaining: Int64,
        contentDurationRemaining: Double,
        outputPath: URL
    ) -> SlowSpeedWarning? {
        let expectedSpeed = getAverageSpeed()

        // Only warn if significantly slower than expected
        guard currentSpeedMultiplier < expectedSpeed * Self.slowSpeedThreshold else {
            currentSpeedWarning = nil
            return nil
        }

        // Estimate remaining time at current speed
        let estimatedRemaining = contentDurationRemaining / currentSpeedMultiplier

        // Try to determine reason
        let reason = detectSlowSpeedReason(outputPath: outputPath)

        let warning = SlowSpeedWarning(
            currentSpeed: currentSpeedMultiplier,
            expectedSpeed: expectedSpeed,
            estimatedRemaining: estimatedRemaining,
            reason: reason
        )

        currentSpeedWarning = warning
        return warning
    }

    /// Clears any active slow speed warning
    func clearSpeedWarning() {
        currentSpeedWarning = nil
    }

    /// Gets average speed from all records
    private func getAverageSpeed() -> Double {
        guard !records.isEmpty else { return Self.defaultSpeedMultiplier }
        return records.map(\.speedMultiplier).reduce(0, +) / Double(records.count)
    }

    /// Attempts to determine why speed is slow
    private func detectSlowSpeedReason(outputPath: URL) -> SlowSpeedReason {
        let path = outputPath.path

        // Check for network paths
        if path.hasPrefix("/Volumes/") {
            // Check if it's a network mount
            let volumeName = outputPath.pathComponents.dropFirst(2).first ?? ""
            if isNetworkVolume(named: volumeName) {
                return .networkStorage
            }

            // Likely external drive
            return .externalDrive
        }

        // Check for typical external/slow disk patterns
        if path.contains("/media/") || path.contains("/mnt/") {
            return .externalDrive
        }

        return .unknown
    }

    /// Checks if a volume appears to be network storage
    private func isNetworkVolume(named volumeName: String) -> Bool {
        // Common network volume indicators
        let networkPatterns = ["smb", "nfs", "afp", "server", "nas", "share"]
        let lowercaseName = volumeName.lowercased()

        for pattern in networkPatterns {
            if lowercaseName.contains(pattern) {
                return true
            }
        }

        // Check mount type using statfs
        let volumePath = "/Volumes/\(volumeName)"
        var statInfo = statfs()
        if statfs(volumePath, &statInfo) == 0 {
            let fsType = withUnsafePointer(to: &statInfo.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }
            let networkTypes = ["smbfs", "nfs", "afpfs", "webdav"]
            if networkTypes.contains(fsType.lowercased()) {
                return true
            }
        }

        return false
    }

    // MARK: - Statistics

    /// Average throughput in MB/s from recent records
    var averageThroughputMBps: Double? {
        guard !records.isEmpty else { return nil }
        let totalBytes = records.reduce(Int64(0)) { $0 + $1.bytesProcessed }
        let totalSeconds = records.reduce(0.0) { $0 + $1.durationSeconds }
        guard totalSeconds > 0 else { return nil }
        return Double(totalBytes) / totalSeconds / (1024 * 1024)
    }

    /// Clears all historical records
    func clearHistory() {
        records.removeAll()
        saveRecords()
    }
}
