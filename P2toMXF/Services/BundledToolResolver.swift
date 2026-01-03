import Foundation

/// Centralized resolver for bundled command-line tools
/// Provides consistent path resolution across FFmpegWrapper, BMXWrapper, and VerificationService
enum BundledTool: String, CaseIterable {
    case ffmpeg
    case ffprobe
    case bmxtranswrap
    case mxf2raw

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .ffprobe: return "FFprobe"
        case .bmxtranswrap: return "BMX Transwrap"
        case .mxf2raw: return "MXF2Raw"
        }
    }
}

/// Resolves paths to bundled command-line tools used by the app
struct BundledToolResolver {

    // MARK: - Singleton

    static let shared = BundledToolResolver()

    private init() {}

    // MARK: - Path Resolution

    /// Resolves the path for a bundled tool
    /// Checks app bundle first, then Homebrew locations for FFmpeg/FFprobe
    /// - Parameter tool: The tool to find
    /// - Returns: URL to the tool if found, nil otherwise
    func path(for tool: BundledTool) -> URL? {
        // First check app bundle Resources
        if let bundledPath = Bundle.main.url(forResource: tool.rawValue, withExtension: nil) {
            return bundledPath
        }

        // For FFmpeg/FFprobe, check Homebrew locations as fallback
        if tool == .ffmpeg || tool == .ffprobe {
            return homebrewPath(for: tool)
        }

        // BMX tools are bundle-only (no Homebrew fallback)
        return nil
    }

    /// Checks if a tool is available
    func isAvailable(_ tool: BundledTool) -> Bool {
        path(for: tool) != nil
    }

    /// Checks if all required tools are available
    var allRequiredToolsAvailable: Bool {
        isAvailable(.ffmpeg) && isAvailable(.bmxtranswrap)
    }

    /// Gets the lib directory containing BMX dylibs
    var bmxLibPath: URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let libDir = URL(fileURLWithPath: resourcePath).appendingPathComponent("lib")
        return FileManager.default.fileExists(atPath: libDir.path) ? libDir : nil
    }

    /// Creates environment dictionary with DYLD_LIBRARY_PATH for BMX tools
    func bmxEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let libPath = bmxLibPath {
            env["DYLD_LIBRARY_PATH"] = libPath.path
        }
        return env
    }

    // MARK: - Private

    /// Homebrew fallback paths for FFmpeg tools
    private func homebrewPath(for tool: BundledTool) -> URL? {
        let homebrewPaths = [
            "/opt/homebrew/bin/\(tool.rawValue)",  // Apple Silicon
            "/usr/local/bin/\(tool.rawValue)"       // Intel
        ]

        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    // MARK: - Diagnostics

    /// Returns a diagnostic summary of tool availability
    func diagnosticSummary() -> String {
        var lines: [String] = ["Tool Availability:"]

        for tool in BundledTool.allCases {
            let status: String
            if let url = path(for: tool) {
                let isBundled = url.path.contains(".app/")
                status = "✓ \(url.path) (\(isBundled ? "bundled" : "system"))"
            } else {
                status = "✗ not found"
            }
            lines.append("  \(tool.displayName): \(status)")
        }

        if let libPath = bmxLibPath {
            lines.append("  BMX Libraries: ✓ \(libPath.path)")
        } else {
            lines.append("  BMX Libraries: ✗ not found")
        }

        return lines.joined(separator: "\n")
    }
}
