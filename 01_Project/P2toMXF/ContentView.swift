import SwiftUI
import AppKit

// MARK: - Content View

/// Main application view orchestrating the P2 to MXF conversion workflow
struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()
    @StateObject private var queueManager = QueueManager.shared
    @State private var showingP2Picker = false
    @State private var showingOutputPicker = false
    @State private var showConsole = false
    @State private var showQueue = true

    var body: some View {
        VStack(spacing: 0) {
            // Main content area (fixed minimum height)
            VStack(spacing: 0) {
                // Header
                HeaderView(
                    viewModel: viewModel,
                    queueManager: queueManager,
                    showQueue: $showQueue,
                    showConsole: $showConsole
                )
                .padding()
                .background(Theme.primaryBackground)

                Divider()

                // Three-column layout: Cards | Clips | Queue
                HStack(spacing: 0) {
                    // Left: Card list
                    CardListView(viewModel: viewModel, showingP2Picker: $showingP2Picker)
                        .fileImporter(
                            isPresented: $showingP2Picker,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                // Use viewModel's tracked access (released when card is removed)
                                _ = viewModel.startSecurityAccess(for: url)
                                viewModel.loadP2Cards(from: url)
                            }
                        }

                    Divider()

                    // Middle: Clip list for active card
                    VStack(spacing: 0) {
                        if let card = viewModel.activeCard {
                            clipListView(card: card)
                        } else {
                            emptyStateView
                        }
                    }
                    .frame(minWidth: 400)
                    .background(Theme.secondaryBackground)

                    // Right: Queue panel
                    if showQueue {
                        Divider()
                        QueueListView()
                            .frame(minWidth: 280, idealWidth: 350, maxWidth: 450)
                    }
                }

                Divider()

                // Footer with settings and convert button
                FooterControlsView(
                    viewModel: viewModel,
                    queueManager: queueManager,
                    showingOutputPicker: $showingOutputPicker
                )
                .padding()
                .background(Theme.primaryBackground)
                .fileImporter(
                    isPresented: $showingOutputPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        // Release previous output directory access if any
                        if let oldDir = viewModel.settings.outputDirectory {
                            viewModel.stopSecurityAccess(for: oldDir)
                        }
                        // Track new access (released when changed or app terminates)
                        _ = viewModel.startSecurityAccess(for: url)
                        viewModel.settings.outputDirectory = url
                    }
                }
            }
            .frame(minHeight: 600)  // Keeps toolbar + 3 columns + footer readable; console adds its own height

            // Console drawer - extends window when visible
            if showConsole {
                Divider()
                ConsoleView(
                    viewModel: viewModel,
                    queueManager: queueManager,
                    showConsole: $showConsole
                )
                .frame(height: 150)
            }
        }
        .frame(minWidth: 1280)
        .animation(.easeInOut(duration: 0.2), value: showConsole)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openP2Card)) { _ in
            showingP2Picker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseTempFolder)) { _ in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a folder for BMX temp files during conversion. " +
                "Pick a drive with plenty of free space for large P2 jobs."
            if let current = TempDirectoryManager.shared.customTempDirectory {
                panel.directoryURL = current
            }
            if panel.runModal() == .OK, let url = panel.url {
                _ = TempDirectoryManager.shared.setCustomTempDirectory(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetTempFolder)) { _ in
            TempDirectoryManager.shared.setCustomTempDirectory(nil)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Card Selected")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Load a P2 card from the panel on the left")
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

                // Parse error warning
                if card.hasParseErrors {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(card.parseErrors.count) clip(s) failed to load")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .help(card.parseErrors.map { "\($0.fileName): \($0.errorMessage)" }.joined(separator: "\n"))
                }

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
}

// MARK: - Preview

#Preview {
    ContentView()
}
