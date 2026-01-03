import Foundation
import SwiftUI

@MainActor
class ConversionViewModel: ObservableObject {
    // Services
    private let parser = P2CardParser()
    private let ffmpeg = FFmpegWrapper()
    let thumbnailManager: ThumbnailManager

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
    @Published var consoleLog: String = ""

    /// Feedback message after adding to queue
    @Published var queueFeedback: String?

    /// Current progress metrics for active conversion
    @Published var progressMetrics = ProgressMetrics()

    /// Timer for updating elapsed time display
    private var elapsedTimer: Timer?

    var hasFFmpeg: Bool {
        ffmpeg.isFFmpegAvailable
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        consoleLog += "[\(timestamp)] \(message)\n"
    }

    func clearConsole() {
        consoleLog = ""
    }

    // MARK: - Progress Timer

    /// Starts the elapsed time timer and initializes progress metrics
    private func startProgressTimer(totalClips: Int) {
        progressMetrics = ProgressMetrics()
        progressMetrics.startTime = Date()
        progressMetrics.totalClips = totalClips
        progressMetrics.phase = "Starting..."

        // Update elapsed time every second for smooth UI updates
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Trigger UI update by touching the progressMetrics
                // The elapsedSeconds computed property will recalculate
                self?.objectWillChange.send()
            }
        }
    }

    /// Stops the elapsed time timer
    private func stopProgressTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Updates progress metrics from FFmpeg callback
    private func updateMetrics(_ metrics: ProgressMetrics) {
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

    // MARK: - Record Groups

    /// Clips segmented into groups by span metadata (preferred) or timecode continuity (fallback)
    var recordGroups: [RecordGroup] {
        let clips = sortedAllClips
        guard !clips.isEmpty else { return [] }

        // Step 1: Build span groups from clips with matching GlobalShotID
        let spanGroups = buildSpanGroups(from: clips)
        let spannedClipIDs = Set(spanGroups.flatMap { $0.map { $0.id } })

        // Step 2: Group remaining (non-spanned) clips by timecode continuity
        let unspannedClips = clips.filter { !spannedClipIDs.contains($0.id) }
        let continuousGroups = groupByTimecodeContinuity(unspannedClips)

        // Step 3: Combine all groups with appropriate types
        var allGroups: [RecordGroup] = []

        // Add span groups
        for spanGroup in spanGroups {
            let groupType: RecordGroup.GroupType = spanGroup.count > 1 ? .spanned : .single
            allGroups.append(RecordGroup(clips: spanGroup, groupIndex: 0, groupType: groupType))
        }

        // Add continuous groups
        for group in continuousGroups {
            let groupType: RecordGroup.GroupType = group.count > 1 ? .continuous : .single
            allGroups.append(RecordGroup(clips: group, groupIndex: 0, groupType: groupType))
        }

        // Sort all groups by first clip's timecode
        allGroups.sort { ($0.clips.first?.startTimecode ?? "") < ($1.clips.first?.startTimecode ?? "") }

        // Re-index after sorting
        return allGroups.enumerated().map { index, group in
            RecordGroup(clips: group.clips, groupIndex: index + 1, groupType: group.groupType)
        }
    }

    /// Builds span groups from clips sharing the same GlobalShotID
    private func buildSpanGroups(from clips: [P2Clip]) -> [[P2Clip]] {
        // Group clips by GlobalShotID
        var shotIDToClips: [String: [P2Clip]] = [:]

        for clip in clips {
            if let shotID = clip.globalShotID {
                shotIDToClips[shotID, default: []].append(clip)
            }
        }

        // Build ordered span groups (only groups with actual spanning)
        var spanGroups: [[P2Clip]] = []

        for (_, spannedClips) in shotIDToClips {
            // Order clips by following the Previous/Next chain
            let ordered = orderSpannedClips(spannedClips)
            spanGroups.append(ordered)
        }

        return spanGroups
    }

    /// Orders spanned clips by following the Previous/Next chain
    private func orderSpannedClips(_ clips: [P2Clip]) -> [P2Clip] {
        guard clips.count > 1 else { return clips }

        // Find the first clip (no previous)
        guard let first = clips.first(where: { $0.spanPreviousClipID == nil }) else {
            // Fallback to timecode order if chain is broken
            return clips.sorted { $0.startTimecode < $1.startTimecode }
        }

        var ordered: [P2Clip] = [first]
        var current = first

        // Follow the Next chain
        while let nextID = current.spanNextClipID,
              let next = clips.first(where: { $0.globalClipID == nextID }) {
            ordered.append(next)
            current = next
        }

        // If we didn't get all clips, append any missing ones (broken chain)
        if ordered.count < clips.count {
            let orderedIDs = Set(ordered.map { $0.id })
            let missing = clips.filter { !orderedIDs.contains($0.id) }
                .sorted { $0.startTimecode < $1.startTimecode }
            ordered.append(contentsOf: missing)
        }

        return ordered
    }

    /// Groups clips by timecode continuity (fallback for non-spanned clips)
    private func groupByTimecodeContinuity(_ clips: [P2Clip]) -> [[P2Clip]] {
        guard !clips.isEmpty else { return [] }

        let sorted = clips.sorted { $0.startTimecode < $1.startTimecode }
        var groups: [[P2Clip]] = [[sorted[0]]]

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]

            if areContinuous(prev, curr) {
                groups[groups.count - 1].append(curr)
            } else {
                groups.append([curr])
            }
        }

        return groups
    }

    /// Check if two consecutive clips are timecode-continuous
    private func areContinuous(_ clip1: P2Clip, _ clip2: P2Clip) -> Bool {
        guard let frameRate = Double(clip1.frameRate), frameRate > 0,
              let duration1 = Int(clip1.duration),
              let tc1 = Timecode(string: clip1.startTimecode, frameRate: frameRate),
              let tc2 = Timecode(string: clip2.startTimecode, frameRate: frameRate) else {
            return false
        }

        let gap = Timecode.frameGap(from: tc1, duration1Frames: duration1, to: tc2)
        return gap == 0
    }

    /// Groups where ALL clips are selected
    var fullySelectedGroups: [RecordGroup] {
        recordGroups.filter { isGroupFullySelected($0) }
    }

    /// Check if all clips in a group are selected
    func isGroupFullySelected(_ group: RecordGroup) -> Bool {
        group.clips.allSatisfy { selectedClips.contains($0.id) }
    }

    /// Check if some (but not all) clips in a group are selected
    func isGroupPartiallySelected(_ group: RecordGroup) -> Bool {
        let selectedCount = group.clips.filter { selectedClips.contains($0.id) }.count
        return selectedCount > 0 && selectedCount < group.clips.count
    }

    /// Select all clips in a group
    func selectGroup(_ group: RecordGroup) {
        for clip in group.clips {
            selectedClips.insert(clip.id)
        }
    }

    /// Deselect all clips in a group
    func deselectGroup(_ group: RecordGroup) {
        for clip in group.clips {
            selectedClips.remove(clip.id)
        }
    }

    /// Toggle selection of all clips in a group
    func toggleGroupSelection(_ group: RecordGroup) {
        if isGroupFullySelected(group) {
            deselectGroup(group)
        } else {
            selectGroup(group)
        }
    }

    /// Check for timecode continuity issues between consecutive clips
    var timecodeIssues: [(clip1: P2Clip, clip2: P2Clip, gapFrames: Int)] {
        let clips = sortedSelectedClips
        guard clips.count > 1 else { return [] }

        var issues: [(clip1: P2Clip, clip2: P2Clip, gapFrames: Int)] = []

        for i in 0..<(clips.count - 1) {
            let clip1 = clips[i]
            let clip2 = clips[i + 1]

            // Parse frame rate (stored as string like "25" or "50")
            guard let frameRate = Double(clip1.frameRate), frameRate > 0 else { continue }

            // Parse duration (stored as frame count string)
            guard let duration1 = Int(clip1.duration) else { continue }

            // Parse timecodes
            guard let tc1 = Timecode(string: clip1.startTimecode, frameRate: frameRate),
                  let tc2 = Timecode(string: clip2.startTimecode, frameRate: frameRate) else { continue }

            // Calculate gap
            let gap = Timecode.frameGap(from: tc1, duration1Frames: duration1, to: tc2)

            if gap != 0 {
                issues.append((clip1: clip1, clip2: clip2, gapFrames: gap))
            }
        }

        return issues
    }

    /// Warning message for TC discontinuity (nil if no issues)
    var tcWarningMessage: String? {
        guard !timecodeIssues.isEmpty else { return nil }

        let descriptions = timecodeIssues.map { issue in
            let gap = issue.gapFrames
            let desc = gap > 0 ? "gap of \(gap) frames" : "overlap of \(abs(gap)) frames"
            return "\(issue.clip1.displayName) → \(issue.clip2.displayName): \(desc)"
        }

        return descriptions.joined(separator: "; ")
    }

    /// Whether conversion can proceed based on current settings
    var canConvert: Bool {
        guard settings.outputDirectory != nil, hasFFmpeg else { return false }

        switch settings.processingMode {
        case .concatenate:
            // Valid when: filename provided AND at least one group fully selected
            return !effectiveOutputFilename.isEmpty && !fullySelectedGroups.isEmpty
        case .individual:
            // Valid when any clips selected
            return selectedClipCount > 0
        }
    }

    init() {
        self.thumbnailManager = ThumbnailManager(ffmpeg: ffmpeg)
        Task {
            ffmpegVersion = await ffmpeg.getVersionInfo()
        }
    }

    // MARK: - P2 Card Loading

    func loadP2Card(from url: URL) {
        // Check if this card is already loaded (by path)
        if loadedCards.contains(where: { $0.rootPath == url }) {
            errorMessage = "This P2 card is already loaded"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let card = try parser.parseP2Card(at: url)
                self.loadedCards.append(card)
                self.activeCardId = card.id
                // Auto-select all clips in the new card
                self.selectedClips = Set(card.clips.map { $0.id })
                self.conversionStatus = [:]
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    /// Set the active card and update selection
    func setActiveCard(_ card: P2Card) {
        activeCardId = card.id
        // Select all clips in the newly active card
        selectedClips = Set(card.clips.map { $0.id })
        conversionStatus = [:]
    }

    /// Remove a card from the loaded cards list
    func removeCard(_ card: P2Card) {
        loadedCards.removeAll { $0.id == card.id }

        // If we removed the active card, switch to another
        if activeCardId == card.id {
            activeCardId = loadedCards.first?.id
            if let newActive = activeCard {
                selectedClips = Set(newActive.clips.map { $0.id })
            } else {
                selectedClips = []
            }
        }
        conversionStatus = [:]
    }

    /// Check if a card is the active one
    func isActiveCard(_ card: P2Card) -> Bool {
        activeCardId == card.id || (activeCardId == nil && loadedCards.first?.id == card.id)
    }

    /// Reload the active card from disk
    func refreshActiveCard() {
        guard let card = activeCard else { return }
        let rootPath = card.rootPath

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let refreshedCard = try parser.parseP2Card(at: rootPath)
                // Replace the old card with refreshed data
                if let index = loadedCards.firstIndex(where: { $0.id == card.id }) {
                    loadedCards[index] = refreshedCard
                }
                activeCardId = refreshedCard.id
                selectedClips = Set(refreshedCard.clips.map { $0.id })
                conversionStatus = [:]
            } catch {
                self.errorMessage = "Refresh failed: \(error.localizedDescription)"
            }
            self.isLoading = false
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

    // MARK: - Conversion

    func startConversion() {
        guard let outputDir = settings.outputDirectory else {
            errorMessage = "Please select an output directory"
            return
        }

        let clipsToProcess = sortedSelectedClips
        guard !clipsToProcess.isEmpty else {
            errorMessage = "No clips selected"
            return
        }

        isCancelled = false
        isConverting = true
        let ext = settings.outputContainer.fileExtension

        switch settings.processingMode {
        case .concatenate:
            startConcatenateConversion(clips: clipsToProcess, outputDir: outputDir, ext: ext)
        case .individual:
            startIndividualConversion(clips: clipsToProcess, outputDir: outputDir, ext: ext)
        }
    }

    private func startConcatenateConversion(clips: [P2Clip], outputDir: URL, ext: String) {
        let groups = fullySelectedGroups
        let groupCount = groups.count
        let totalClips = groups.reduce(0) { $0 + $1.clipCount }

        log("Starting merge of \(groupCount) group(s) to \(ext.uppercased())")
        log("Output directory: \(outputDir.path)")
        log("FFmpeg path: \(ffmpeg.ffmpegPath?.path ?? "NOT FOUND")")

        // Mark all clips in selected groups as pending
        for group in groups {
            for clip in group.clips {
                conversionStatus[clip.id] = .pending
            }
        }

        // Start progress timer
        startProgressTimer(totalClips: totalClips)

        Task {
            defer { stopProgressTimer() }

            var successCount = 0
            var failCount = 0

            for (groupIdx, group) in groups.enumerated() {
                // Check for cancellation before starting each group
                if isCancelled {
                    log("Cancellation requested, stopping...")
                    break
                }

                // Build output filename with numeric suffix if multiple groups
                let suffix = groupCount > 1 ? String(format: "_%02d", groupIdx + 1) : ""
                let outputName = "\(effectiveOutputFilename)\(suffix).\(ext)"
                let outputURL = outputDir.appendingPathComponent(outputName)

                log("--- Group \(group.groupIndex) (\(group.clipCount) clips) ---")
                log("Output: \(outputName)")
                log("Clips:")
                for (i, clip) in group.clips.enumerated() {
                    log("  \(i + 1). \(clip.displayName) [TC: \(clip.startTimecode)]")
                }

                // Mark clips in this group as in progress
                for clip in group.clips {
                    conversionStatus[clip.id] = .inProgress(progress: 0)
                }

                do {
                    // Update phase for this group
                    progressMetrics.phase = "Group \(groupIdx + 1)/\(groupCount): \(group.clipCount) clips"
                    progressMetrics.currentClipIndex = groupIdx + 1

                    try await ffmpeg.mergeClips(group.clips, to: outputURL, settings: settings) { progress, status in
                        Task { @MainActor in
                            for clip in group.clips {
                                self.conversionStatus[clip.id] = .inProgress(progress: progress)
                            }
                            // Update phase with current status
                            self.progressMetrics.phase = status
                            self.progressMetrics.progress = progress
                        }
                    } logHandler: { message in
                        Task { @MainActor in
                            self.log(message)
                        }
                    } metricsHandler: { metrics in
                        Task { @MainActor in
                            self.updateMetrics(metrics)
                        }
                    }

                    // Check if cancelled during conversion
                    if isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    } else {
                        // Brief finalizing state for cleanup phase
                        for clip in group.clips {
                            conversionStatus[clip.id] = .finalizing
                        }
                        progressMetrics.phase = "Finalizing \(outputName)..."

                        // Small delay to show finalizing state (cleanup happens here)
                        try? await Task.sleep(for: .milliseconds(200))

                        for clip in group.clips {
                            conversionStatus[clip.id] = .completed
                        }
                        log("SUCCESS: Created \(outputName)")
                        successCount += 1
                    }

                } catch is CancellationError {
                    // Swift Task.checkCancellation() throws CancellationError
                    for clip in group.clips {
                        conversionStatus[clip.id] = .pending
                    }
                    log("Cancelled before completing \(group.clipCount) clips")
                    break
                } catch let error as FFmpegWrapper.FFmpegError {
                    // Check if it's a cancellation
                    if case .cancelled = error {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                        break
                    }
                    // Other FFmpeg errors
                    if !isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        }
                        log("FAILED: \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    }
                } catch {
                    // Don't show error if cancelled
                    if !isCancelled {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        }
                        log("FAILED: \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        for clip in group.clips {
                            conversionStatus[clip.id] = .pending
                        }
                    }
                }
            }

            if isCancelled {
                log("Conversion cancelled")
            } else {
                log("Merge complete: \(successCount) group(s) succeeded, \(failCount) failed")
            }
            isConverting = false
        }
    }

    private func startIndividualConversion(clips: [P2Clip], outputDir: URL, ext: String) {
        log("Starting individual conversion of \(clips.count) clips to \(ext.uppercased())")
        log("Output directory: \(outputDir.path)")

        // Mark all clips as pending
        for clip in clips {
            conversionStatus[clip.id] = .pending
        }

        // Start progress timer
        startProgressTimer(totalClips: clips.count)

        Task {
            defer { stopProgressTimer() }

            var successCount = 0
            var failCount = 0

            for (index, clip) in clips.enumerated() {
                // Check for cancellation before starting each clip
                if isCancelled {
                    log("Cancellation requested, stopping...")
                    break
                }

                let outputName = "\(clip.displayName).\(ext)"
                let outputURL = outputDir.appendingPathComponent(outputName)

                log("[\(index + 1)/\(clips.count)] Converting \(clip.displayName)...")
                conversionStatus[clip.id] = .inProgress(progress: 0)

                // Update phase for this clip
                progressMetrics.phase = "Clip \(index + 1)/\(clips.count): \(clip.displayName)"
                progressMetrics.currentClipIndex = index + 1

                do {
                    try await ffmpeg.rewrapSingleClip(clip, to: outputURL, outputFormat: ext, settings: settings) { progress, status in
                        Task { @MainActor in
                            self.conversionStatus[clip.id] = .inProgress(progress: progress)
                            // Calculate overall progress across all clips
                            let overallProgress = (Double(index) + progress) / Double(clips.count)
                            self.progressMetrics.progress = overallProgress
                            self.progressMetrics.phase = status.isEmpty ? "Clip \(index + 1)/\(clips.count)" : status
                        }
                    } logHandler: { message in
                        Task { @MainActor in
                            self.log(message)
                        }
                    } metricsHandler: { metrics in
                        Task { @MainActor in
                            // Adjust progress for overall clip context
                            var adjusted = metrics
                            adjusted.progress = (Double(index) + metrics.progress) / Double(clips.count)
                            adjusted.currentClipIndex = index + 1
                            self.updateMetrics(adjusted)
                        }
                    }

                    // Check if cancelled during conversion
                    if isCancelled {
                        conversionStatus[clip.id] = .pending
                    } else {
                        // Brief finalizing state for cleanup phase
                        conversionStatus[clip.id] = .finalizing
                        progressMetrics.phase = "Finalizing \(outputName)..."

                        // Small delay to show finalizing state
                        try? await Task.sleep(for: .milliseconds(200))

                        conversionStatus[clip.id] = .completed
                        log("SUCCESS: Created \(outputName)")
                        successCount += 1
                    }

                } catch is CancellationError {
                    // Swift Task.checkCancellation() throws CancellationError
                    conversionStatus[clip.id] = .pending
                    log("Cancelled during \(clip.displayName)")
                    break
                } catch let error as FFmpegWrapper.FFmpegError {
                    // Check if it's a cancellation
                    if case .cancelled = error {
                        conversionStatus[clip.id] = .pending
                        break
                    }
                    // Other FFmpeg errors
                    if !isCancelled {
                        conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        log("FAILED: \(clip.displayName) - \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        conversionStatus[clip.id] = .pending
                    }
                } catch {
                    // Don't show error if cancelled
                    if !isCancelled {
                        conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                        log("FAILED: \(clip.displayName) - \(error.localizedDescription)")
                        failCount += 1
                    } else {
                        conversionStatus[clip.id] = .pending
                    }
                }
            }

            if isCancelled {
                log("Conversion cancelled")
            } else {
                log("Conversion complete: \(successCount) succeeded, \(failCount) failed")
            }
            isConverting = false
        }
    }

    func cancelConversion() {
        isCancelled = true
        ffmpeg.cancelConversion()
        isConverting = false
        log("Conversion cancelled by user")
    }

    // MARK: - Queue Integration

    /// Adds the current selection to the batch queue
    /// - Parameters:
    ///   - autoStart: If true, immediately starts queue processing (for "Convert Now")
    /// - Returns: True if successfully added, false if validation failed
    @discardableResult
    func addToQueue(autoStart: Bool = false) -> Bool {
        guard let card = p2Card else {
            errorMessage = "No P2 card loaded"
            return false
        }

        guard let outputDir = settings.outputDirectory else {
            errorMessage = "Please select an output directory"
            return false
        }

        switch settings.processingMode {
        case .concatenate:
            return addConcatenateJobsToQueue(card: card, outputDir: outputDir, autoStart: autoStart)
        case .individual:
            return addIndividualJobToQueue(card: card, outputDir: outputDir, autoStart: autoStart)
        }
    }

    /// Adds concatenate jobs to queue (one per fully selected group)
    private func addConcatenateJobsToQueue(card: P2Card, outputDir: URL, autoStart: Bool) -> Bool {
        let groups = fullySelectedGroups
        guard !groups.isEmpty else {
            errorMessage = "No groups fully selected for merging"
            return false
        }

        guard !effectiveOutputFilename.isEmpty else {
            errorMessage = "Please enter an output filename"
            return false
        }

        let ext = settings.outputContainer.fileExtension
        let queueManager = QueueManager.shared

        for (index, group) in groups.enumerated() {
            // Build output filename with numeric suffix if multiple groups
            let suffix = groups.count > 1 ? String(format: "_%02d", index + 1) : ""
            let outputName = "\(effectiveOutputFilename)\(suffix).\(ext)"
            let outputURL = outputDir.appendingPathComponent(outputName)

            // Only autoStart on the first job (to trigger queue processing)
            let shouldAutoStart = autoStart && index == 0
            queueManager.addJob(
                cardName: card.name,
                cardPath: card.rootPath,
                clips: group.clips,
                settings: settings,
                destinationURL: outputURL,
                autoStart: shouldAutoStart
            )
        }

        let jobCount = groups.count
        if autoStart {
            queueFeedback = "Started \(jobCount) job\(jobCount == 1 ? "" : "s")"
        } else {
            queueFeedback = "Added \(jobCount) job\(jobCount == 1 ? "" : "s") to queue"
        }

        // Auto-clear after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            queueFeedback = nil
        }

        return true
    }

    /// Adds an individual files job to queue
    private func addIndividualJobToQueue(card: P2Card, outputDir: URL, autoStart: Bool) -> Bool {
        let clips = sortedSelectedClips
        guard !clips.isEmpty else {
            errorMessage = "No clips selected"
            return false
        }

        let queueManager = QueueManager.shared

        // For individual mode, destination is the directory
        queueManager.addJob(
            cardName: card.name,
            cardPath: card.rootPath,
            clips: clips,
            settings: settings,
            destinationURL: outputDir,
            autoStart: autoStart
        )

        let clipCount = clips.count
        if autoStart {
            queueFeedback = "Started job (\(clipCount) clip\(clipCount == 1 ? "" : "s"))"
        } else {
            queueFeedback = "Added job (\(clipCount) clip\(clipCount == 1 ? "" : "s")) to queue"
        }

        // Auto-clear after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            queueFeedback = nil
        }

        return true
    }

    /// Whether a job can be added to the queue (same validation as canConvert)
    var canAddToQueue: Bool {
        canConvert
    }
}
