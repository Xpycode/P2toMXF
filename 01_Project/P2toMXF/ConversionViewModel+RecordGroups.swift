import Foundation

extension ConversionViewModel {

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
}
