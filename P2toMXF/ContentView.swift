import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()
    @State private var showingP2Picker = false
    @State private var showingOutputPicker = false
    @State private var showConsole = true

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

            // Console output
            if showConsole && !viewModel.consoleLog.isEmpty {
                Divider()
                consoleView
            }

            Divider()

            // Footer with settings and convert button
            footerView
                .padding()
                .background(.ultraThinMaterial)
        }
        .frame(minWidth: 850, minHeight: 500)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
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

            VStack(alignment: .trailing, spacing: 2) {
                Text("P2 to MXF Converter")
                    .font(.headline)

                if !viewModel.hasFFmpeg {
                    Label("FFmpeg not found", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Console

    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console")
                    .font(.caption.bold())
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.consoleLog, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Button("Clear") {
                    viewModel.clearConsole()
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
                    Text(viewModel.consoleLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.9))
                .onChange(of: viewModel.consoleLog) { _, _ in
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

                Text("\(card.clipCount) clips")
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

            // Clips table
            List(card.clips, selection: $viewModel.selectedClips) { clip in
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

            // TC Warning (only in concatenate mode with issues)
            if viewModel.settings.processingMode == .concatenate,
               let warning = viewModel.tcWarningMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }

            Divider()

            // Row 3: Action button
            HStack {
                Spacer()

                if viewModel.isConverting {
                    Button("Cancel") {
                        viewModel.cancelConversion()
                    }
                    .buttonStyle(.bordered)

                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        viewModel.startConversion()
                    } label: {
                        Label(convertButtonLabel, systemImage: convertButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canConvert)
                }
            }
        }
    }

    // MARK: - Helpers

    private var convertButtonLabel: String {
        let count = viewModel.selectedClipCount
        switch viewModel.settings.processingMode {
        case .concatenate:
            return "Merge \(count) Clips"
        case .individual:
            return "Convert \(count) Clips"
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
