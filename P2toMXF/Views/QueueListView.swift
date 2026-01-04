import SwiftUI

// MARK: - Queue List View

/// Panel showing the batch conversion queue with job list and controls
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

                // Slow speed warning banner
                if let warning = queueManager.slowSpeedWarning {
                    SlowSpeedBanner(warning: warning) {
                        queueManager.dismissSlowSpeedWarning()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

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
            headerStatusSummary
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

    // MARK: - Header Status Summary

    @ViewBuilder
    private var headerStatusSummary: some View {
        if queueManager.isProcessing {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                if let estimate = queueManager.currentJobEstimate {
                    Text(estimate.formattedEstimate)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        } else if queueManager.pendingCount > 0, let totalEstimate = queueManager.getTotalQueueEstimate() {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(totalEstimate.formattedEstimate)
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .help("Total estimated time for \(queueManager.pendingCount) pending job(s)")
        } else if !queueManager.jobs.isEmpty {
            Text("\(queueManager.completedCount)/\(queueManager.jobs.count) done")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    JobRowView(job: job, queueManager: queueManager)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Queue Controls

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

// MARK: - Preview

#Preview {
    QueueListView()
        .frame(width: 400)
}
