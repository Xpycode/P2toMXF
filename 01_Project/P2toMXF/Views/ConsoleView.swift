import SwiftUI
import AppKit

// MARK: - Console View

/// Console panel displaying FFmpeg/BMX output logs
struct ConsoleView: View {
    @ObservedObject var viewModel: ConversionViewModel
    @ObservedObject var queueManager: QueueManager
    @Binding var showConsole: Bool

    /// Determines which console to show: queue (when processing) or local
    private var activeConsoleLog: String {
        if queueManager.isProcessing || !queueManager.consoleLog.isEmpty {
            return queueManager.consoleLog
        }
        return viewModel.consoleLog
    }

    /// Whether currently showing the queue console vs local
    private var isShowingQueueConsole: Bool {
        queueManager.isProcessing || !queueManager.consoleLog.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
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

            // Log content
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
}
