import SwiftUI

/// Panel showing the batch conversion queue
struct QueueListView: View {
    @ObservedObject var queueManager = QueueManager.shared
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            queueHeader

            // Collapsible content
            if isExpanded {
                Divider()

                if queueManager.jobs.isEmpty {
                    emptyState
                } else {
                    jobList
                }

                // Queue controls footer
                if !queueManager.jobs.isEmpty {
                    Divider()
                    queueControls
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var queueHeader: some View {
        HStack(spacing: 8) {
            // Expand/collapse button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            // Queue icon and title
            Label("Queue", systemImage: "list.bullet.rectangle")
                .font(.subheadline.bold())

            // Badge for pending jobs
            if queueManager.pendingCount > 0 {
                Text("\(queueManager.pendingCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }

            Spacer()

            // Status summary
            if queueManager.isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if queueManager.isVerifying {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Verifying...")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if !queueManager.jobs.isEmpty {
                Text("\(queueManager.completedCount)/\(queueManager.jobs.count) done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)

            Text("No jobs in queue")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Use \"Add to Queue\" to queue conversions")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Job List

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(queueManager.jobs) { job in
                    JobRowView(job: job)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 200)
    }

    // MARK: - Controls

    private var queueControls: some View {
        HStack(spacing: 12) {
            // Clear completed
            if queueManager.completedCount > 0 || queueManager.failedCount > 0 {
                Button {
                    queueManager.clearFinishedJobs()
                } label: {
                    Label("Clear Finished", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Verify All button (when there are unverified completed jobs)
            if queueManager.unverifiedCompletedCount > 0 && !queueManager.isVerifying {
                Menu {
                    Button("Quick Verify All") {
                        queueManager.verifyAllCompleted(mode: .quick)
                    }
                    Button("Full Verify All") {
                        queueManager.verifyAllCompleted(mode: .full)
                    }
                } label: {
                    Label("Verify (\(queueManager.unverifiedCompletedCount))", systemImage: "checkmark.seal")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Cancel verification
            if queueManager.isVerifying {
                Button {
                    queueManager.cancelVerification()
                } label: {
                    Label("Stop Verify", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Cancel all pending
            if queueManager.pendingCount > 0 && !queueManager.isProcessing {
                Button {
                    queueManager.cancelAllPending()
                } label: {
                    Text("Cancel All")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            // Start Queue button (when not processing)
            if queueManager.hasPendingJobs && !queueManager.isProcessing {
                Button {
                    queueManager.startQueue()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Cancel current
            if queueManager.isProcessing {
                Button {
                    queueManager.cancelCurrentJob()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Job Row View

struct JobRowView: View {
    let job: ConversionJob
    @ObservedObject var queueManager = QueueManager.shared

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            statusIcon
                .frame(width: 20)

            // Job info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.caption.bold())
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(job.cardName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Text("\(job.clips.count) clips")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Text(job.outputFormat)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Progress or action button
            trailingContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(backgroundColor)
        .contentShape(Rectangle())
    }

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

    @ViewBuilder
    private var trailingContent: some View {
        switch job.status {
        case .pending:
            Button {
                queueManager.removeJob(job.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")

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

#Preview {
    QueueListView()
        .frame(width: 400)
}
