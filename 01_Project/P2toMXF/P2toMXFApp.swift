import SwiftUI

@main
struct P2toMXFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open P2 Card...") {
                    NotificationCenter.default.post(name: .openP2Card, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openP2Card = Notification.Name("openP2Card")
}
