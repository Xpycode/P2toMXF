import SwiftUI

// MARK: - Footer Controls View

/// Footer panel with conversion settings and action buttons
struct FooterControlsView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @ObservedObject var queueManager: QueueManager
    @Binding var showingOutputPicker: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Row 1: Format, Mode, Audio, Preserve TC
            settingsRow

            Divider()

            // Row 2: Output Directory, Use folder name checkbox, Filename
            outputRow

            // Group selection hint (only in concatenate mode with partial selections)
            groupSelectionHint

            Divider()

            // Row 3: Action buttons OR Progress Panel
            actionRow
        }
        .animation(.easeInOut(duration: 0.2), value: isAnyConversionActive)
        .animation(.easeInOut(duration: 0.2), value: viewModel.queueFeedback)
        .animation(.easeInOut(duration: 0.2), value: queueManager.hasPendingJobs)
    }

    // MARK: - Settings Row

    private var settingsRow: some View {
        HStack(spacing: 20) {
            // Format picker
            HStack(spacing: 8) {
                Text("Format")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("", selection: $viewModel.settings.outputContainer) {
                    ForEach(ConversionSettings.OutputContainer.allCases, id: \.self) { container in
                        Text(container.rawValue).tag(container)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
            }

            // Mode picker
            HStack(spacing: 8) {
                Text("Mode")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("", selection: $viewModel.settings.processingMode) {
                    ForEach(ConversionSettings.ProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
            }

            // Audio picker
            HStack(spacing: 8) {
                Text("Audio")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("", selection: $viewModel.settings.audioMapping) {
                    ForEach(ConversionSettings.AudioMapping.allCases, id: \.self) { mapping in
                        Text(mapping.rawValue).tag(mapping)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                // Warning when audio mixing + MXF (will use FFmpeg instead of BMX)
                if viewModel.settings.audioMapping != .allChannels && viewModel.settings.outputContainer == .mxf {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                        .help("Audio mixing requires FFmpeg instead of BMX for MXF output. This may affect MXF compatibility with some NLEs.")
                }
            }

            // Preserve TC checkbox
            Toggle("Preserve TC", isOn: $viewModel.settings.preserveTimecode)
                .toggleStyle(.checkbox)

            Spacer()
        }
    }

    // MARK: - Output Row

    private var outputRow: some View {
        HStack(spacing: 16) {
            // Output directory
            HStack(spacing: 8) {
                Text("Output")
                    .foregroundStyle(.secondary)
                    .fixedSize()

                if let outputDir = viewModel.settings.outputDirectory {
                    Text(outputDir.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                } else {
                    Text("Not selected")
                        .foregroundStyle(.secondary)
                }

                Button("Choose...") {
                    showingOutputPicker = true
                }
                .controlSize(.small)
            }

            // Output filename (only in concatenate mode)
            if viewModel.settings.processingMode == .concatenate {
                // Checkbox first
                Toggle("Use folder name", isOn: $viewModel.settings.useFolderNameAsFilename)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                // Filename field (expands to fill space)
                HStack(spacing: 8) {
                    Text("Filename")
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    if viewModel.settings.useFolderNameAsFilename {
                        Text(viewModel.activeCard?.name ?? "No card selected")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(5)
                    } else {
                        TextField("Enter filename", text: $viewModel.settings.outputFilename)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text(".\(viewModel.settings.outputContainer.fileExtension)")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Group Selection Hint

    @ViewBuilder
    private var groupSelectionHint: some View {
        if viewModel.settings.processingMode == .concatenate {
            let fullCount = viewModel.fullySelectedGroups.count
            let totalCount = viewModel.recordGroups.count
            if fullCount < totalCount && fullCount > 0 {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("\(fullCount) of \(totalCount) groups fully selected - only fully selected groups will be merged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if fullCount == 0 && viewModel.selectedClipCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No groups fully selected - select all clips in at least one group to merge")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Action Row

    @ViewBuilder
    private var actionRow: some View {
        if isAnyConversionActive {
            // Progress panel with cancel button
            HStack(spacing: 16) {
                ProgressControlPanel(
                    metrics: activeProgressMetrics,
                    onCancel: cancelActiveConversion
                )

                Button("Stop") {
                    cancelActiveConversion()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        } else {
            // Normal action buttons
            HStack {
                // Queue feedback message
                if let feedback = viewModel.queueFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer()

                // Add to Queue button
                Button {
                    viewModel.addToQueue()
                } label: {
                    Label("Add to Queue", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canAddToQueue)
                .help("Add current selection to the batch queue")

                // Context-aware primary action button
                if queueManager.hasPendingJobs {
                    // Queue has pending jobs - show "Start Queue"
                    Button {
                        queueManager.startQueue()
                    } label: {
                        Label("Start Queue (\(queueManager.pendingCount))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Start processing \(queueManager.pendingCount) queued job\(queueManager.pendingCount == 1 ? "" : "s")")
                } else {
                    // No pending jobs - show "Convert Now" (adds to queue and starts)
                    Button {
                        viewModel.addToQueue(autoStart: true)
                    } label: {
                        Label(convertButtonLabel, systemImage: convertButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canConvert)
                    .help("Add to queue and start conversion immediately")
                }
            }
        }
    }

    // MARK: - Helpers

    /// True when any conversion is happening (direct or via queue)
    private var isAnyConversionActive: Bool {
        viewModel.isConverting || queueManager.isProcessing
    }

    /// Gets the active progress metrics (from direct conversion or queue)
    private var activeProgressMetrics: ProgressMetrics {
        if viewModel.isConverting {
            return viewModel.progressMetrics
        } else if queueManager.isProcessing, let activeJob = queueManager.activeJob {
            // Build metrics from queue job
            var metrics = ProgressMetrics()
            metrics.progress = activeJob.progress
            metrics.phase = "Processing: \(activeJob.displayName)"
            metrics.currentClipIndex = max(1, Int(activeJob.progress * Double(activeJob.clips.count)) + 1)
            metrics.totalClips = activeJob.clips.count
            metrics.startTime = activeJob.startedAt
            return metrics
        }
        return ProgressMetrics()
    }

    /// Cancel handler for active conversion
    private func cancelActiveConversion() {
        if viewModel.isConverting {
            viewModel.cancelConversion()
        } else if queueManager.isProcessing {
            queueManager.cancelCurrentJob()
        }
    }

    /// Label for the convert button based on mode
    private var convertButtonLabel: String {
        switch viewModel.settings.processingMode {
        case .concatenate:
            let groupCount = viewModel.fullySelectedGroups.count
            return groupCount == 1 ? "Merge 1 Group" : "Merge \(groupCount) Groups"
        case .individual:
            let clipCount = viewModel.selectedClipCount
            return clipCount == 1 ? "Convert 1 Clip" : "Convert \(clipCount) Clips"
        }
    }

    /// Icon for the convert button based on mode
    private var convertButtonIcon: String {
        switch viewModel.settings.processingMode {
        case .concatenate:
            return "arrow.triangle.merge"
        case .individual:
            return "square.and.arrow.down.on.square"
        }
    }
}
