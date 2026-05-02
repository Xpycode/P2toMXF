import Foundation
import SwiftUI
import Sparkle
import Combine

/// Owns the Sparkle updater and exposes `canCheckForUpdates` for menu bindings.
///
/// Create a single instance at app launch via `@StateObject` on the App struct,
/// and pass its `updater.checkForUpdates()` into the "Check for Updates…" menu
/// action.
@MainActor
final class UpdaterController: ObservableObject {
    /// The underlying Sparkle updater controller. Starts checking on init.
    let updaterController: SPUStandardUpdaterController

    /// Published flag tracking whether the updater can perform a check right now
    /// (false briefly during a running check). Bind to a menu item's `.disabled(...)`.
    @Published var canCheckForUpdates = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)
            .store(in: &cancellables)
    }

    /// Invokes the user-initiated update check.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
