import SwiftUI
import AppKit

// MARK: - Content View

/// Main application view orchestrating the P2 to MXF conversion workflow
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
            HeaderView(
                viewModel: viewModel,
                queueManager: queueManager,
                showQueue: $showQueue,
                showConsole: $showConsole
            )
            .padding()
            .background(.ultraThinMaterial)

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
                            _ = url.startAccessingSecurityScopedResource()
                            viewModel.loadP2Card(from: url)
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

                    // Console output (below clip list)
                    if showConsole {
                        Divider()
                        ConsoleView(
                            viewModel: viewModel,
                            queueManager: queueManager,
                            showConsole: $showConsole
                        )
                    }
                }
                .frame(minWidth: 400)

                // Right: Queue panel
                if showQueue {
                    Divider()
                    QueueListView()
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 350)
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
            .background(.ultraThinMaterial)
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
        }
        .frame(minWidth: 1150, minHeight: 600)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
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
