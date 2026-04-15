import Foundation

/// Pure helper for querying volume capacity and identity.
/// Used by TempDirectoryManager, the preflight disk-space check, and error-message enrichment.
enum DiskSpace {

    /// Returns available capacity in bytes for important (user-initiated) writes at the given URL's volume.
    /// Falls back to the legacy `volumeAvailableCapacityKey` if the "important usage" key is unavailable.
    /// Returns `nil` if the URL's volume can't be queried (e.g. the path no longer exists).
    static func availableCapacity(for url: URL) -> Int64? {
        let keys: [URLResourceKey] = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            return nil
        }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let raw = values.volumeAvailableCapacity {
            return Int64(raw)
        }
        return nil
    }

    /// Returns the user-facing name of the volume containing the given URL (e.g. "Macintosh HD", "1TB extra").
    /// Returns `nil` if the URL's volume can't be queried.
    static func volumeName(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeNameKey]) else {
            return nil
        }
        return values.volumeName
    }

    /// Returns true if both URLs reside on the same volume.
    /// If either lookup fails, returns false (conservative — treats unknown as different volumes).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard
            let aValues = try? a.resourceValues(forKeys: [.volumeURLKey]),
            let bValues = try? b.resourceValues(forKeys: [.volumeURLKey]),
            let aVolume = aValues.volume,
            let bVolume = bValues.volume
        else {
            return false
        }
        return aVolume == bVolume
    }

    /// Formats a byte count as a short, human-readable string using GB/MB as appropriate.
    /// Uses the file-size byte counter style (GB not GiB) to match macOS Finder display.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
