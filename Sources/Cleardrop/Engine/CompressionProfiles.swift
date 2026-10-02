import Foundation

// MARK: - Compression profile

/// Frozen discrete compression step. Level 0 = metadata strip only.
/// The `summary` and `detail` strings are what the window and the README show, so they
/// state the numbers the engine uses and nothing it does not do.
struct CompressionProfile: Sendable, Equatable, Identifiable {
    /// Discrete step id: 0...4
    var id: Int
    var name: String
    /// One-line “what you get” (still a PDF).
    var summary: String
    /// Longer blurb for the review panel.
    var detail: String

    /// JPEG photos whose longer side exceeds this many pixels are scaled down to it.
    /// `nil` = images are never resized.
    var maxImageEdge: Int?
    /// JPEG quality 0...1; `nil` = do not re-encode JPEG.
    var jpegQuality: Double?
    /// Lossless Flate re-pack of non-image streams that were stored uncompressed.
    var reflattenStreams: Bool
    var convertNearGrayToGray: Bool

    /// True when this profile may change image pixels (lossy).
    var isLossy: Bool {
        maxImageEdge != nil || jpegQuality != nil
    }

    /// True when export should run image/stream compression beyond metadata strip.
    var appliesCompression: Bool {
        id > 0
    }
}

enum CompressionProfiles {
    /// Product default: metadata clean only, no visual compression.
    static let defaultLevel: Int = 0

    static let minLevel: Int = 0
    static let maxLevel: Int = 4

    /// Shown with every lossy level: which images are touched at all.
    static let eligibilityNote =
        "Only RGB and gray JPEG images are re-encoded. CMYK, masked, non-JPEG and other images are left exactly as they are, and text is never turned into an image."

    /// Ordered table — index == id.
    static let all: [CompressionProfile] = [
        CompressionProfile(
            id: 0,
            name: "None",
            summary: "PDF · metadata removed · pages unchanged",
            detail: "Only removes metadata. Page content and images are left exactly as they are.",
            maxImageEdge: nil,
            jpegQuality: nil,
            reflattenStreams: false,
            convertNearGrayToGray: false
        ),
        CompressionProfile(
            id: 1,
            name: "Light",
            summary: "PDF · lossless · no image is re-encoded",
            detail: "Compresses streams that were stored uncompressed. Most PDFs have none, so this often changes nothing.",
            maxImageEdge: nil,
            jpegQuality: nil,
            reflattenStreams: true,
            convertNearGrayToGray: false
        ),
        CompressionProfile(
            id: 2,
            name: "Balanced",
            summary: "PDF · JPEG photos at quality 80, at most 1600 px",
            detail: "Re-encodes JPEG photos at quality 80. Photos longer than 1600 px on their long side are scaled down to 1600 px; smaller ones keep their size.",
            maxImageEdge: 1600,
            jpegQuality: 0.80,
            reflattenStreams: true,
            convertNearGrayToGray: false
        ),
        CompressionProfile(
            id: 3,
            name: "Strong",
            summary: "PDF · JPEG photos at quality 60, at most 1200 px",
            detail: "Re-encodes JPEG photos at quality 60. Photos longer than 1200 px on their long side are scaled down to 1200 px. Expect visibly softer photos.",
            maxImageEdge: 1200,
            jpegQuality: 0.60,
            reflattenStreams: true,
            convertNearGrayToGray: false
        ),
        CompressionProfile(
            id: 4,
            name: "Maximum",
            summary: "PDF · JPEG photos at quality 42, at most 900 px",
            detail: "Re-encodes JPEG photos at quality 42 and scales them down to at most 900 px. Photos with almost no colour are converted to grayscale. Photos will look soft or blocky.",
            maxImageEdge: 900,
            jpegQuality: 0.42,
            reflattenStreams: true,
            convertNearGrayToGray: true
        ),
    ]

    static func profile(for level: Int) -> CompressionProfile {
        let clamped = min(max(level, minLevel), maxLevel)
        return all[clamped]
    }

    static func clamp(_ level: Int) -> Int {
        min(max(level, minLevel), maxLevel)
    }
}

// MARK: - Byte size formatting

enum ByteSizeFormat {
    /// Human-readable size, e.g. `12.4 MB`, `840 KB`, `512 bytes`.
    static func string(bytes: Int) -> String {
        let n = Double(max(0, bytes))
        if n < 1000 {
            return "\(max(0, bytes)) bytes"
        }
        let kb = n / 1000
        if kb < 1000 {
            return String(format: kb >= 100 ? "%.0f KB" : "%.1f KB", kb)
        }
        let mb = kb / 1000
        if mb < 1000 {
            return String(format: mb >= 100 ? "%.0f MB" : "%.1f MB", mb)
        }
        let gb = mb / 1000
        return String(format: gb >= 100 ? "%.0f GB" : "%.2f GB", gb)
    }
}
