import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()
    @StateObject private var queueManager = QueueManager.shared
    @State private var showingP2Picker = false
    @State private var showingOutputPicker = false
    @State private var showConsole = true
    @State private var showQueue = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding()
                .background(.ultraThinMaterial)

            Divider()

            // Main content
            if let card = viewModel.p2Card {
                clipListView(card: card)
            } else {
                emptyStateView
            }

            // Queue panel
            if showQueue {
                Divider()
                QueueListView()
            }

            // Console output (now shows queue console when queue is active)
            if showConsole {
                Divider()
                consoleView
            }

            Divider()

            // Footer with settings and convert button
            footerView
                .padding()
                .background(.ultraThinMaterial)
        }
        .frame(minWidth: 850, minHeight: 550)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            // Left: Load P2 Card button
            Button {
                showingP2Picker = true
            } label: {
                Label("Load P2 Card", systemImage: "folder.badge.plus")
            }
            .fileImporter(
                isPresented: $showingP2Picker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    _ = url.startAccessingSecurityScopedResource()
                    viewModel.loadP2Card(from: url)
                }
            }

            Spacer()

            // Center: App name and warnings
            VStack(spacing: 2) {
                Text("P2 to MXF Converter")
                    .font(.headline)

                if !viewModel.hasFFmpeg {
                    Label("FFmpeg not found", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Right: Toggle buttons
            HStack(spacing: 12) {
                // Queue toggle
                Button {
                    showQueue.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showQueue ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                        if queueManager.pendingCount > 0 {
                            Text("\(queueManager.pendingCount)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.blue))
                        }
                    }
                }
                .help(showQueue ? "Hide queue panel" : "Show queue panel")

                // Console toggle
                Button {
                    showConsole.toggle()
                } label: {
                    Image(systemName: showConsole ? "terminal.fill" : "terminal")
                }
                .help(showConsole ? "Hide console output" : "Show console output")
            }
        }
    }

    // MARK: - Console

    /// Determines which console to show: queue (when processing) or local
    private var activeConsoleLog: String {
        if queueManager.isProcessing || !queueManager.consoleLog.isEmpty {
            return queueManager.consoleLog
        }
        return viewModel.consoleLog
    }

    private var isShowingQueueConsole: Bool {
        queueManager.isProcessing || !queueManager.consoleLog.isEmpty
    }

    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Text("Console")
                        .font(.caption.bold())
                    if isShowingQueueConsole {
                        Text("(Queue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(activeConsoleLog, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Button("Clear") {
                    if isShowingQueueConsole {
                        queueManager.clearConsole()
                    } else {
                        viewModel.clearConsole()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Button(showConsole ? "Hide" : "Show") {
                    showConsole.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.8))
            .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(activeConsoleLog.isEmpty ? "No output yet" : activeConsoleLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(activeConsoleLog.isEmpty ? Color.secondary : Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.9))
                .onChange(of: activeConsoleLog) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No P2 Card Loaded")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Click \"Load P2 Card\" to select a P2 card folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clip List

    private func clipListView(card: P2Card) -> some View {
        VStack(spacing: 0) {
            // Card info bar
            HStack {
                Label(card.name, systemImage: "sdcard")
                    .font(.subheadline.bold())

                Spacer()

                Text("\(card.clipCount) clips in \(viewModel.recordGroups.count) group(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(viewModel.allClipsSelected ? "Deselect All" : "Select All") {
                    if viewModel.allClipsSelected {
                        viewModel.deselectAllClips()
                    } else {
                        viewModel.selectAllClips()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))

            // Grouped clips list
            List {
                ForEach(viewModel.recordGroups) { group in
                    Section {
                        ForEach(group.clips) { clip in
                            ClipRowView(
                                clip: clip,
                                isSelected: viewModel.selectedClips.contains(clip.id),
                                status: viewModel.conversionStatus[clip.id],
                                thumbnailManager: viewModel.thumbnailManager
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.toggleClipSelection(clip)
                            }
                        }
                    } header: {
                        GroupHeaderView(
                            group: group,
                            isFullySelected: viewModel.isGroupFullySelected(group),
                            isPartiallySelected: viewModel.isGroupPartiallySelected(group),
                            onToggle: { viewModel.toggleGroupSelection(group) }
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 12) {
            // Row 1: Format, Mode, Audio, Preserve TC
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
                }

                // Preserve TC checkbox
                Toggle("Preserve TC", isOn: $viewModel.settings.preserveTimecode)
                    .toggleStyle(.checkbox)

                Spacer()
            }

            Divider()

            // Row 2: Output Directory, Use folder name checkbox, Filename
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

                    Button("Choose…") {
                        showingOutputPicker = true
                    }
                    .controlSize(.small)
                }
                .fileImporter(
                    isPresented: $showingOutputPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        viewModel.settings.outputDirectory = url
                    }
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
                            Text(viewModel.p2Card?.name ?? "No card loaded")
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

            // Group selection hint (only in concatenate mode with partial selections)
            if viewModel.settings.processingMode == .concatenate {
                let fullCount = viewModel.fullySelectedGroups.count
                let totalCount = viewModel.recordGroups.count
                if fullCount < totalCount && fullCount > 0 {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("\(fullCount) of \(totalCount) groups fully selected — only fully selected groups will be merged")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if fullCount == 0 && viewModel.selectedClipCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("No groups fully selected — select all clips in at least one group to merge")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                }
            }

            Divider()

            // Row 3: Action buttons OR Progress Panel
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
        .animation(.easeInOut(duration: 0.2), value: isAnyConversionActive)
        .animation(.easeInOut(duration: 0.2), value: viewModel.queueFeedback)
        .animation(.easeInOut(duration: 0.2), value: queueManager.hasPendingJobs)
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

    private var convertButtonIcon: String {
        switch viewModel.settings.processingMode {
        case .concatenate:
            return "arrow.triangle.merge"
        case .individual:
            return "square.and.arrow.down.on.square"
        }
    }
}

// MARK: - Group Header View

struct GroupHeaderView: View {
    let group: RecordGroup
    let isFullySelected: Bool
    let isPartiallySelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Selection checkbox (with mixed state support)
            Button(action: onToggle) {
                Image(systemName: checkboxIcon)
                    .foregroundStyle(isFullySelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // Group info
            Text("Group \(group.groupIndex)")
                .font(.subheadline.bold())

            Text("(\(group.clipCount) clips)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("•")
                .foregroundStyle(.tertiary)

            Text(group.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("•")
                .foregroundStyle(.tertiary)

            Text("TC: \(group.startTimecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var checkboxIcon: String {
        if isFullySelected {
            return "checkmark.circle.fill"
        } else if isPartiallySelected {
            return "minus.circle.fill"
        } else {
            return "circle"
        }
    }
}

// MARK: - Clip Row View

struct ClipRowView: View {
    let clip: P2Clip
    let isSelected: Bool
    let status: ConversionStatus?
    let thumbnailManager: ThumbnailManager

    @State private var thumbnails: ThumbnailManager.ClipThumbnails?
    @State private var isLoadingThumbnails = false

    private let thumbnailHeight: CGFloat = 45
    private let thumbnailWidth: CGFloat = 80  // 16:9 aspect at 45px height

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // Thumbnails (first & last frame)
            HStack(spacing: 2) {
                thumbnailView(image: thumbnails?.first, label: "IN")
                thumbnailView(image: thumbnails?.last, label: "OUT")
            }

            // Clip info
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayName)
                    .font(.body.bold())

                HStack(spacing: 8) {
                    Label(clip.startTimecode.isEmpty ? "--:--:--:--" : clip.startTimecode,
                          systemImage: "clock")
                    Label(clip.formattedDuration, systemImage: "timer")
                    Label(clip.videoCodec, systemImage: "film")
                    Label("\(clip.audioChannels) ch", systemImage: "speaker.wave.2")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Conversion status
            if let status = status {
                statusBadge(for: status)
            }
        }
        .padding(.vertical, 4)
        .task(id: clip.id) {
            // Lazy load thumbnails when row becomes visible
            guard thumbnails == nil else { return }
            isLoadingThumbnails = true
            thumbnails = await thumbnailManager.getThumbnails(for: clip)
            isLoadingThumbnails = false
        }
        .onDisappear {
            // Cancel pending request if row scrolls off screen
            if thumbnails == nil {
                Task {
                    await thumbnailManager.cancelRequest(for: clip.id)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(image: NSImage?, label: String) -> some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.1))

            if let image = image {
                // Thumbnail image
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .clipped()
            } else if isLoadingThumbnails {
                // Loading spinner
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                // Placeholder
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Label overlay (IN/OUT)
            VStack {
                Spacer()
                HStack {
                    Text(label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(2)
                    Spacer()
                }
                .padding(2)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .cornerRadius(4)
    }

    @ViewBuilder
    private func statusBadge(for status: ConversionStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inProgress(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
            }
        case .finalizing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Finalizing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let error):
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(error)
        }
    }
}

#Preview {
    ContentView()
}
