import Foundation

// MARK: - Verification Models

/// Verification mode options
enum VerificationMode: String, CaseIterable, Codable {
    case quick = "Quick"
    case full = "Full"

    var description: String {
        switch self {
        case .quick: return "Container + first/last 5 seconds"
        case .full: return "Decode every frame"
        }
    }
}

/// Status of file verification
enum VerificationStatus: Equatable, Codable {
    case unverified       // Not yet verified
    case verifying        // Currently running verification
    case verified         // Passed verification
    case failed(String)   // Failed with error message

    var displayName: String {
        switch self {
        case .unverified: return "Not Verified"
        case .verifying: return "Verifying..."
        case .verified: return "Verified"
        case .failed: return "Failed"
        }
    }

    var iconName: String {
        switch self {
        case .unverified: return "questionmark.circle"
        case .verifying: return "arrow.triangle.2.circlepath"
        case .verified: return "checkmark.seal.fill"
        case .failed: return "xmark.seal.fill"
        }
    }

    var isFinished: Bool {
        switch self {
        case .verified, .failed: return true
        default: return false
        }
    }

    // MARK: - Codable (custom for associated value)

    private enum CodingKeys: String, CodingKey {
        case type, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "unverified": self = .unverified
        case "verifying": self = .verifying
        case "verified": self = .verified
        case "failed":
            let message = try container.decode(String.self, forKey: .errorMessage)
            self = .failed(message)
        default: self = .unverified
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .unverified: try container.encode("unverified", forKey: .type)
        case .verifying: try container.encode("verifying", forKey: .type)
        case .verified: try container.encode("verified", forKey: .type)
        case .failed(let message):
            try container.encode("failed", forKey: .type)
            try container.encode(message, forKey: .errorMessage)
        }
    }
}

/// Detailed results from verification
struct VerificationResult: Codable {
    let fileURL: URL
    let passed: Bool
    let mode: VerificationMode
    let duration: TimeInterval         // How long verification took
    let framesDecoded: Int?            // Number of frames successfully decoded
    let totalFrames: Int?              // Expected total frames
    let decodingSpeed: String?         // e.g., "45.2x"
    let containerValid: Bool           // MXF/MOV structure is valid
    let errorMessage: String?          // If failed, what went wrong
    let verifiedAt: Date

    var summary: String {
        if passed {
            var parts = ["✓ Verified"]
            if let frames = framesDecoded {
                parts.append("\(frames) frames")
            }
            if let speed = decodingSpeed {
                parts.append(speed)
            }
            parts.append(String(format: "%.1fs", duration))
            return parts.joined(separator: " • ")
        } else {
            return "✗ Failed: \(errorMessage ?? "Unknown error")"
        }
    }
}
