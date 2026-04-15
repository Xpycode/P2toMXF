import SwiftUI
import AppKit

// MARK: - Job Row View

/// Single row displaying a conversion job in the queue with status and controls
struct JobRowView: View {
    let job: ConversionJob
    @ObservedObject var queueManager: QueueManager

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            statusIcon
                .frame(width: 20)

            // Job info
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text("\(job.clips.count) clips")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\u{2022}")
                        .foregroundStyle(.tertiary)

                    Text(job.outputFormat)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // Progress or action button
            trailingContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .contentShape(Rectangle())
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .preparing:
            ProgressView()
                .scaleEffect(0.5)
        case .active:
            ProgressView()
                .scaleEffect(0.5)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Trailing Content

    @ViewBuilder
    private var trailingContent: some View {
        switch job.status {
        case .pending:
            HStack(spacing: 8) {
                Button {
                    queueManager.removeJob(job.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }

        case .preparing, .active:
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: job.progress)
                    .frame(width: 60)
                Text("\(Int(job.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .completed:
            completedTrailingContent

        case .failed(let error):
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Failed")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                    Text(shortErrorMessage(error))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .help(error)

                Button {
                    queueManager.retryJob(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Retry")
            }

        case .cancelled:
            HStack(spacing: 4) {
                Text("Cancelled")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                Button {
                    queueManager.retryJob(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Retry")
            }
        }
    }

    // MARK: - Completed Trailing Content

    /// Content shown for completed jobs (verification status + controls)
    @ViewBuilder
    private var completedTrailingContent: some View {
        switch job.verificationStatus {
        case .unverified:
            HStack(spacing: 6) {
                Text("Done")
                    .font(.caption2)
                    .foregroundStyle(.green)

                revealInFinderButton

                // Verify menu - use Picker-style menu for better click handling
                verifyMenuButton(isRetry: false)
            }

        case .verifying:
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: job.verificationProgress)
                    .frame(width: 60)
                Text("Verifying...")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }

        case .verified:
            verifiedContent

        case .failed(let error):
            HStack(spacing: 4) {
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text("Verify Failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help(error)

                revealInFinderButton

                // Retry verification
                verifyMenuButton(isRetry: true)
            }
        }
    }

    // MARK: - Reveal in Finder

    /// Reveals the actual output file in Finder with selection.
    /// Renders nothing if the job has no recorded output URLs.
    @ViewBuilder
    private var revealInFinderButton: some View {
        if let url = job.actualOutputURLs.first {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
    }

    // MARK: - Verify Menu Button

    /// Creates a verify menu button with proper click handling
    /// Using Button + contextMenu pattern to avoid SwiftUI Menu click issues
    @ViewBuilder
    private func verifyMenuButton(isRetry: Bool) -> some View {
        Menu {
            Button {
                queueManager.verifyJob(job.id, mode: .quick)
            } label: {
                Label(isRetry ? "Retry Quick" : "Quick Verify", systemImage: "bolt")
            }
            Button {
                queueManager.verifyJob(job.id, mode: .full)
            } label: {
                Label(isRetry ? "Retry Full" : "Full Verify", systemImage: "checkmark.seal")
            }
        } label: {
            Image(systemName: isRetry ? "arrow.clockwise" : "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20, height: 20)  // Explicit hit target
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isRetry ? "Retry verification" : "Verify output file")
        .id("\(job.id)-verify-\(isRetry)")  // Stable identity for SwiftUI
    }

    // MARK: - Verified Content

    /// Content shown when verification passed - shows details + re-verify option
    @ViewBuilder
    private var verifiedContent: some View {
        HStack(spacing: 6) {
            if let result = job.verificationResult {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)

                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Verified")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)

                        // Show verification details (mode + speed)
                        HStack(spacing: 2) {
                            Text(result.mode.rawValue)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            if let speed = result.decodingSpeed {
                                Text("•")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(speed)
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .help(result.summary)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Verified")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            revealInFinderButton

            // Re-verify menu (allows running different verification mode)
            Menu {
                Button {
                    queueManager.verifyJob(job.id, mode: .quick)
                } label: {
                    Label("Re-verify (Quick)", systemImage: "bolt")
                }
                Button {
                    queueManager.verifyJob(job.id, mode: .full)
                } label: {
                    Label("Re-verify (Full)", systemImage: "checkmark.seal")
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Run verification again")
            .id("\(job.id)-reverify")
        }
    }

    // MARK: - Error Message Formatting

    /// Reduces a multi-line, technical error into a concise one- or two-line summary
    /// suitable for inline display. Maps common failure modes to human-readable causes.
    private func shortErrorMessage(_ error: String) -> String {
        let lower = error.lowercased()

        // Recognize common POSIX / libMXF failure modes.
        if lower.contains("error code 28") || lower.contains("no space") {
            // Query the current free space of both the temp and output volumes.
            // The one with the least free space is the likely culprit.
            let tempURL = TempDirectoryManager.shared.effectiveTempDirectory
            let outputURL = job.destinationURL.deletingLastPathComponent()

            let tempFree = DiskSpace.availableCapacity(for: tempURL)
            let outputFree = DiskSpace.availableCapacity(for: outputURL)

            // Prefer whichever has less free space (the one that filled up).
            let culprit: URL?
            switch (tempFree, outputFree) {
            case let (t?, o?):
                culprit = t <= o ? tempURL : outputURL
            case (.some, nil):
                culprit = tempURL
            case (nil, .some):
                culprit = outputURL
            default:
                culprit = nil
            }

            if let culprit,
               let name = DiskSpace.volumeName(for: culprit),
               let free = DiskSpace.availableCapacity(for: culprit) {
                return "Out of space on \(name) (\(DiskSpace.formatBytes(free)) free)"
            }
            return "Disk full"
        }
        if lower.contains("error code 13") || lower.contains("permission denied") {
            return "Permission denied"
        }
        if lower.contains("error code 30") || lower.contains("read-only") {
            return "Volume is read-only"
        }
        if lower.contains("cannot access source") {
            return "Source folder inaccessible"
        }
        if lower.contains("cannot access output") {
            return "Output folder inaccessible"
        }

        // Fallback: take the first non-empty line, trim prefixes like "ERROR: ",
        // "BMX conversion failed: ", and drop internal paths like "near bmx/…".
        let firstLine = error
            .split(whereSeparator: { $0.isNewline })
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { String($0) } ?? error

        var cleaned = firstLine
        for prefix in ["BMX conversion failed:", "ERROR (libMXF):", "ERROR:", "Error:"] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Background Color

    private var backgroundColor: Color {
        switch job.status {
        case .active, .preparing:
            return Color.blue.opacity(0.1)
        case .failed:
            return Color.red.opacity(0.05)
        default:
            // Highlight if currently verifying
            if job.verificationStatus == .verifying {
                return Color.orange.opacity(0.1)
            }
            return Color.clear
        }
    }
}
