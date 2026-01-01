import Foundation
import SwiftUI

@MainActor
class ConversionViewModel: ObservableObject {
    // Services
    private let parser = P2CardParser()
    private let ffmpeg = FFmpegWrapper()

    // State
    @Published var p2Card: P2Card?
    @Published var selectedClips: Set<UUID> = []
    @Published var conversionStatus: [UUID: ConversionStatus] = [:]
    @Published var settings = ConversionSettings()

    @Published var isLoading = false
    @Published var isConverting = false
    @Published var errorMessage: String?
    @Published var ffmpegVersion: String?
    @Published var consoleLog: String = ""

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
        guard selectedClipCount > 0,
              settings.outputDirectory != nil,
              hasFFmpeg else { return false }

        switch settings.processingMode {
        case .concatenate:
            return !effectiveOutputFilename.isEmpty && timecodeIssues.isEmpty
        case .individual:
            return true
        }
    }

    init() {
        Task {
            ffmpegVersion = await ffmpeg.getVersionInfo()
        }
    }

    // MARK: - P2 Card Loading

    func loadP2Card(from url: URL) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let card = try parser.parseP2Card(at: url)
                self.p2Card = card
                // Auto-select all clips
                self.selectedClips = Set(card.clips.map { $0.id })
                self.conversionStatus = [:]
            } catch {
                self.errorMessage = error.localizedDescription
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
        let outputName = "\(effectiveOutputFilename).\(ext)"
        let outputURL = outputDir.appendingPathComponent(outputName)

        log("Starting merge of \(clips.count) clips into single \(ext.uppercased())")
        log("Output directory: \(outputDir.path)")
        log("FFmpeg path: \(ffmpeg.ffmpegPath?.path ?? "NOT FOUND")")

        // Mark all clips as in progress
        for clip in clips {
            conversionStatus[clip.id] = .inProgress(progress: 0)
        }

        log("Output file: \(outputName)")
        log("Clips in order:")
        for (i, clip) in clips.enumerated() {
            log("  \(i + 1). \(clip.displayName) [TC: \(clip.startTimecode)]")
        }

        Task {
            do {
                try await ffmpeg.mergeClips(clips, to: outputURL, settings: settings) { progress, message in
                    Task { @MainActor in
                        for clip in clips {
                            self.conversionStatus[clip.id] = .inProgress(progress: progress)
                        }
                    }
                } logHandler: { message in
                    Task { @MainActor in
                        self.log(message)
                    }
                }

                for clip in clips {
                    conversionStatus[clip.id] = .completed
                }
                log("SUCCESS: Created \(outputName)")

            } catch {
                for clip in clips {
                    conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                }
                log("FAILED: \(error.localizedDescription)")
            }

            log("Merge complete")
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

        Task {
            var successCount = 0
            var failCount = 0

            for (index, clip) in clips.enumerated() {
                let outputName = "\(clip.displayName).\(ext)"
                let outputURL = outputDir.appendingPathComponent(outputName)

                log("[\(index + 1)/\(clips.count)] Converting \(clip.displayName)...")
                conversionStatus[clip.id] = .inProgress(progress: 0)

                do {
                    try await ffmpeg.rewrapSingleClip(clip, to: outputURL, outputFormat: ext, settings: settings) { progress, _ in
                        Task { @MainActor in
                            self.conversionStatus[clip.id] = .inProgress(progress: progress)
                        }
                    } logHandler: { message in
                        Task { @MainActor in
                            self.log(message)
                        }
                    }

                    conversionStatus[clip.id] = .completed
                    log("SUCCESS: Created \(outputName)")
                    successCount += 1

                } catch {
                    conversionStatus[clip.id] = .failed(error: error.localizedDescription)
                    log("FAILED: \(clip.displayName) - \(error.localizedDescription)")
                    failCount += 1
                }
            }

            log("Conversion complete: \(successCount) succeeded, \(failCount) failed")
            isConverting = false
        }
    }

    func cancelConversion() {
        ffmpeg.cancelConversion()
        isConverting = false
    }
}
