import SwiftUI
import AppKit

// MARK: - Header View

/// Header bar showing card count, app title, warnings, and toggle buttons
struct HeaderView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @ObservedObject var queueManager: QueueManager
    @Binding var showQueue: Bool
    @Binding var showConsole: Bool

    var body: some View {
        HStack {
            // Left: Card count summary
            if !viewModel.loadedCards.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sdcard.fill")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.loadedCards.count) card\(viewModel.loadedCards.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
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

            // Right: Action and toggle buttons
            HStack(spacing: 12) {
                // Refresh active card
                Button {
                    viewModel.refreshActiveCard()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.activeCard == nil || viewModel.isLoading)
                .help("Reload P2 card from disk")

                // Open output folder
                Button {
                    if let outputDir = viewModel.settings.outputDirectory {
                        NSWorkspace.shared.open(outputDir)
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(viewModel.settings.outputDirectory == nil)
                .help("Open output folder in Finder")

                // Queue toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showQueue.toggle()
                    }
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showConsole.toggle()
                    }
                } label: {
                    Image(systemName: showConsole ? "terminal.fill" : "terminal")
                }
                .help(showConsole ? "Hide console output" : "Show console output")
            }
        }
    }
}
