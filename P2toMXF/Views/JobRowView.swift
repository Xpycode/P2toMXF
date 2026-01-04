import SwiftUI

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
            Image(systemName: "xmark.circle.fill")
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
                // Show estimate
                QueueEstimateBadge(estimate: queueManager.getEstimate(for: job))

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
            HStack(spacing: 4) {
                Text("Failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
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

                // Verify menu
                Menu {
                    Button {
                        queueManager.verifyJob(job.id, mode: .quick)
                    } label: {
                        Label("Quick Verify", systemImage: "bolt")
                    }
                    Button {
                        queueManager.verifyJob(job.id, mode: .full)
                    } label: {
                        Label("Full Verify", systemImage: "checkmark.seal")
                    }
                } label: {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Verify output file")
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
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Verified")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            .help(job.verificationResult?.summary ?? "File verified successfully")

        case .failed(let error):
            HStack(spacing: 4) {
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text("Verify Failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help(error)

                // Retry verification
                Menu {
                    Button {
                        queueManager.verifyJob(job.id, mode: .quick)
                    } label: {
                        Label("Retry Quick", systemImage: "bolt")
                    }
                    Button {
                        queueManager.verifyJob(job.id, mode: .full)
                    } label: {
                        Label("Retry Full", systemImage: "checkmark.seal")
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
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
