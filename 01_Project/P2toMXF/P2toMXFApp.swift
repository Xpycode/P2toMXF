import SwiftUI

@main
struct P2toMXFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 900)
        .commands {
            FileMenuCommands()
        }
    }
}

/// File-menu additions. Wrapped in its own `Commands` struct so that `@ObservedObject`
/// changes from `TempDirectoryManager` actually propagate into the menu — a direct
/// `.commands { CommandGroup(...) }` closure does not observe ObservableObjects reliably.
struct FileMenuCommands: Commands {
    @ObservedObject private var tempManager = TempDirectoryManager.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Text("Current Temp: \(currentTempLabel)")
            Divider()

            Button("Open P2 Card...") {
                NotificationCenter.default.post(name: .openP2Card, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Temp Folder\u{2026}") {
                NotificationCenter.default.post(name: .chooseTempFolder, object: nil)
            }
            Button("Reset Temp Folder") {
                NotificationCenter.default.post(name: .resetTempFolder, object: nil)
            }
            .disabled(!tempManager.hasCustomDirectory)
        }
    }

    private var currentTempLabel: String {
        guard tempManager.hasCustomDirectory else { return "System Default" }
        let url = tempManager.effectiveTempDirectory
        return DiskSpace.volumeName(for: url) ?? url.lastPathComponent
    }
}

extension Notification.Name {
    static let openP2Card = Notification.Name("openP2Card")
    static let chooseTempFolder = Notification.Name("chooseTempFolder")
    static let resetTempFolder = Notification.Name("resetTempFolder")
}
