import Foundation
import SwiftUI

/// App-level preference for the temp directory used during BMX rewrap + FFmpeg concatenation.
/// If the user has set a custom directory, it is used; otherwise the system default
/// (`FileManager.default.temporaryDirectory`, which lives on the boot volume) is used.
///
/// Not per-job — intentionally app-wide. Persisted in UserDefaults as a path string.
/// No security-scoped bookmark is used because the app is not sandboxed.
@MainActor
final class TempDirectoryManager: ObservableObject {

    @MainActor static let shared = TempDirectoryManager()

    private static let defaultsKey = "P2toMXF.customTempDirectoryPath"

    /// User-chosen custom temp directory. `nil` means use system default.
    @Published private(set) var customTempDirectory: URL?

    /// The directory that should actually be used right now.
    /// Resolves to `customTempDirectory` if set AND reachable; otherwise system temp.
    var effectiveTempDirectory: URL {
        if let custom = customTempDirectory, Self.isUsable(custom) {
            return custom
        }
        return FileManager.default.temporaryDirectory
    }

    /// True if the user has set a custom directory (regardless of whether it's currently reachable).
    var hasCustomDirectory: Bool {
        customTempDirectory != nil
    }

    private init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.defaultsKey) {
            let url = URL(fileURLWithPath: path)
            if Self.isUsable(url) {
                customTempDirectory = url
            } else {
                // Stale / unreachable — silently drop.
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    /// Sets (or clears, when passed `nil`) the custom temp directory.
    /// Validates that the directory exists and is writable; returns `false` if validation fails.
    @discardableResult
    func setCustomTempDirectory(_ url: URL?) -> Bool {
        let defaults = UserDefaults.standard
        guard let url else {
            customTempDirectory = nil
            defaults.removeObject(forKey: Self.defaultsKey)
            return true
        }

        guard Self.isUsable(url) else {
            return false
        }

        customTempDirectory = url
        defaults.set(url.path, forKey: Self.defaultsKey)
        return true
    }

    /// True if the given URL is a directory that exists and is writable.
    private static func isUsable(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return fm.isWritableFile(atPath: url.path)
    }
}
