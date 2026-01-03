import Foundation
import CryptoKit

// MARK: - Report Generator

/// Generates XML reports documenting P2 conversions
struct ReportGenerator {

    // MARK: - Public API

    /// Generate a conversion report XML file
    /// - Parameters:
    ///   - job: The completed conversion job
    ///   - outputFiles: List of output files created (for individual mode, multiple files)
    ///   - includeChecksum: Whether to compute MD5 checksums (slower for large files)
    /// - Returns: URL of the generated report file
    @discardableResult
    static func generateReport(
        for job: ConversionJob,
        outputFiles: [URL],
        includeChecksum: Bool
    ) async throws -> URL {
        let reportURL = reportURL(for: job.destinationURL)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <P2ConversionReport>
            <Created>\(ISO8601DateFormatter().string(from: Date()))</Created>
            <Application version="\(appVersion)">P2toMXF</Application>

        """

        // Settings section
        xml += """
            <Settings>
                <Mode>\(escapeXML(job.settings.processingMode.rawValue))</Mode>
                <OutputFormat>\(job.settings.outputContainer.rawValue)</OutputFormat>
                <AudioMapping>\(escapeXML(job.settings.audioMapping.rawValue))</AudioMapping>
                <PreserveTimecode>\(job.settings.preserveTimecode)</PreserveTimecode>
            </Settings>

        """

        // Source section
        xml += """
            <Source card="\(escapeXML(job.cardName))">
                <Path>\(escapeXML(job.cardPath.path))</Path>
                <ClipCount>\(job.clips.count)</ClipCount>

        """

        // Individual clips
        for (index, clip) in job.clips.enumerated() {
            xml += clipXML(clip, index: index + 1)
        }

        xml += """
            </Source>

        """

        // Output section
        xml += "    <Outputs>\n"
        for outputFile in outputFiles {
            xml += await outputXML(for: outputFile, includeChecksum: includeChecksum)
        }
        xml += "    </Outputs>\n"

        xml += "</P2ConversionReport>\n"

        try xml.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    /// Get the report URL for a given output file
    static func reportURL(for outputURL: URL) -> URL {
        let directory = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(baseName)_report.xml")
    }

    // MARK: - Private Helpers

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static func clipXML(_ clip: P2Clip, index: Int) -> String {
        var xml = """
                <Clip index="\(index)">
                    <Name>\(escapeXML(clip.displayName))</Name>
                    <Timecode>\(clip.startTimecode)</Timecode>
                    <Duration>\(clip.formattedDuration)</Duration>
                    <Codec>\(escapeXML(clip.videoCodec))</Codec>
                    <FrameRate>\(clip.frameRate)</FrameRate>
                    <VideoFile>\(escapeXML(clip.videoFiles.first?.lastPathComponent ?? ""))</VideoFile>
                    <AudioFiles>

        """

        for (i, audioFile) in clip.audioFiles.enumerated() {
            xml += "                    <Audio channel=\"\(i + 1)\">\(escapeXML(audioFile.lastPathComponent))</Audio>\n"
        }

        xml += """
                    </AudioFiles>
                </Clip>

        """
        return xml
    }

    private static func outputXML(for fileURL: URL, includeChecksum: Bool) async -> String {
        var xml = "        <Output>\n"
        xml += "            <Filename>\(escapeXML(fileURL.lastPathComponent))</Filename>\n"
        xml += "            <Path>\(escapeXML(fileURL.path))</Path>\n"

        // File metadata
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            if let size = attributes[.size] as? Int64 {
                xml += "            <FileSize>\(size)</FileSize>\n"
                xml += "            <FileSizeFormatted>\(formatFileSize(size))</FileSizeFormatted>\n"
            }
            if let created = attributes[.creationDate] as? Date {
                xml += "            <CreatedAt>\(ISO8601DateFormatter().string(from: created))</CreatedAt>\n"
            }
        }

        // Optional checksum
        if includeChecksum {
            if let checksum = await computeMD5(for: fileURL) {
                xml += "            <Checksum algorithm=\"MD5\">\(checksum)</Checksum>\n"
            }
        }

        xml += "        </Output>\n"
        return xml
    }

    /// Compute MD5 checksum using streaming (memory-efficient for large files)
    private static func computeMD5(for fileURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let stream = InputStream(url: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }

                stream.open()
                defer { stream.close() }

                var hasher = Insecure.MD5()
                let bufferSize = 1024 * 1024  // 1MB chunks
                var buffer = [UInt8](repeating: 0, count: bufferSize)

                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        hasher.update(data: Data(buffer[0..<bytesRead]))
                    } else {
                        break
                    }
                }

                let digest = hasher.finalize()
                let checksum = digest.map { String(format: "%02x", $0) }.joined()
                continuation.resume(returning: checksum)
            }
        }
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
