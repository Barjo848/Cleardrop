import Foundation

// MARK: - Stream inventory

/// Byte breakdown of a parsed PDF for size estimates.
struct PDFSizeInventory: Sendable, Equatable {
    /// Image XObject / DCTDecode stream payloads.
    var imageStreamBytes: Int
    /// `/Type /Metadata` stream payloads (stripped on export).
    var metadataStreamBytes: Int
    /// All other stream payloads (content, fonts as streams, etc.).
    var otherStreamBytes: Int
    /// Original file size on disk.
    var fileSizeBytes: Int
    /// The part of `imageStreamBytes` in images the lossy levels can re-encode.
    /// `nil` when unknown, in which case all image bytes are assumed to qualify.
    var recompressibleImageBytes: Int? = nil

    /// Non-stream structure (xref, objects, dicts) approximated.
    var overheadBytes: Int {
        max(0, fileSizeBytes - imageStreamBytes - metadataStreamBytes - otherStreamBytes)
    }

    var totalStreamBytes: Int {
        imageStreamBytes + metadataStreamBytes + otherStreamBytes
    }

    /// Fraction of file that is image payloads (0...1).
    var imageFraction: Double {
        guard fileSizeBytes > 0 else { return 0 }
        return Double(imageStreamBytes) / Double(fileSizeBytes)
    }

    /// True when compression is unlikely to help much.
    var isTextHeavy: Bool {
        imageFraction < 0.15
    }

    static func from(graph: PDFDocumentGraph, fileSizeBytes: Int) -> PDFSizeInventory {
        var image = 0
        var meta = 0
        var other = 0
        var recompressible = 0

        for (_, entry) in graph.objects {
            guard case .stream(let dict, let data) = entry.value else { continue }
            let n = data.count
            if ImageRecompressor.isEligible(dict: dict, data: data) {
                recompressible += n
            }
            if case .name(let t) = dict["Type"], t == "Metadata" {
                meta += n
                continue
            }
            let isImageXObject: Bool = {
                if case .name(let t) = dict["Type"], t == "XObject",
                   case .name(let s) = dict["Subtype"], s == "Image"
                {
                    return true
                }
                return false
            }()
            if isImageXObject || ImageMetadataStripper.isDCTDecode(dict) {
                image += n
            } else {
                other += n
            }
        }

        return PDFSizeInventory(
            imageStreamBytes: image,
            metadataStreamBytes: meta,
            otherStreamBytes: other,
            fileSizeBytes: max(0, fileSizeBytes),
            recompressibleImageBytes: recompressible
        )
    }
}

// MARK: - Size estimate

struct SizeEstimate: Sendable, Equatable {
    var bytesLow: Int
    var bytesHigh: Int
    /// 0...1
    var confidence: Double
    /// "heuristic" | "exact"
    var method: String

    var bytesMid: Int {
        (bytesLow + bytesHigh) / 2
    }

    var isExact: Bool { method == "exact" }

    /// Single-line UI string, e.g. `~3.1 MB` or `~2.8–3.6 MB`.
    func displayString() -> String {
        let lo = ByteSizeFormat.string(bytes: bytesLow)
        let hi = ByteSizeFormat.string(bytes: bytesHigh)
        if bytesHigh <= 0 {
            return ByteSizeFormat.string(bytes: 0)
        }
        if isExact {
            // Tight band around measured export
            if lo == hi || Double(bytesHigh - bytesLow) / Double(max(1, bytesHigh)) < 0.04 {
                return ByteSizeFormat.string(bytes: bytesMid)
            }
        }
        let span = Double(bytesHigh - bytesLow) / Double(max(bytesHigh, 1))
        if span < 0.08 || lo == hi {
            return "~\(hi)"
        }
        return "~\(lo)–\(hi)"
    }

    func savingsLine(originalBytes: Int) -> String? {
        guard originalBytes > 0, bytesMid < originalBytes else { return nil }
        let pct = Int(((Double(originalBytes - bytesMid) / Double(originalBytes)) * 100).rounded())
        guard pct >= 1 else { return nil }
        return "−\(pct)%"
    }

    func confidenceCaption() -> String {
        if isExact {
            return "Measured from a dry-run export"
        }
        if confidence >= 0.8 {
            return "Estimate"
        }
        if confidence >= 0.6 {
            return "Rough estimate"
        }
        return "Rough estimate — actual may differ"
    }
}

// MARK: - Export naming

enum ExportNaming {
    /// Suggested save filename for strip + compression profile.
    static func suggestedFileName(original: URL, profile: CompressionProfile) -> String {
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix: String
        switch CompressionProfiles.clamp(profile.id) {
        case 0: suffix = "clean"
        case 1: suffix = "clean-light"
        case 2: suffix = "clean-balanced"
        case 3: suffix = "clean-strong"
        default: suffix = "clean-max"
        }
        return "\(stem)-\(suffix).pdf"
    }
}

// MARK: - Heuristic + probe estimator

enum SizeEstimator {
    /// Files at or under this size get an exact dry-run probe.
    static let probeMaxBytes: Int = 15 * 1024 * 1024

    /// Instant heuristic after strip + compression profile.
    /// Levels are **monotone non-increasing** in `bytesHigh`.
    static func estimate(inventory: PDFSizeInventory, profile: CompressionProfile) -> SizeEstimate {
        let mids = midpoints(inventory: inventory)
        let level = CompressionProfiles.clamp(profile.id)
        let mid = mids[level]
        let original = max(1, inventory.fileSizeBytes)

        let confidence: Double
        let band: Double
        switch level {
        case 0:
            confidence = 0.80
            band = inventory.isTextHeavy ? 0.25 : 0.08
        case 1:
            confidence = 0.70
            band = inventory.isTextHeavy ? 0.25 : 0.10
        default:
            confidence = inventory.isTextHeavy ? 0.55 : 0.60
            // Lossy JPEG ratios vary a lot by content
            band = inventory.isTextHeavy ? 0.20 : 0.45
        }

        var low = Int((mid * (1.0 - band)).rounded())
        var high = Int((mid * (1.0 + band)).rounded())
        let cap = Int(Double(original) * 1.05)
        low = min(max(1, low), cap)
        high = min(max(low, high), cap)

        if level > 0 {
            let prevHigh = estimate(
                inventory: inventory,
                profile: CompressionProfiles.profile(for: level - 1)
            ).bytesHigh
            high = min(high, prevHigh)
            low = min(low, high)
        }

        return SizeEstimate(
            bytesLow: low,
            bytesHigh: high,
            confidence: confidence,
            method: "heuristic"
        )
    }

    /// Full dry-run sanitize for accurate size (small/medium files only).
    static func probe(
        data: Data,
        options: SanitizeOptions = .default,
        profile: CompressionProfile
    ) -> SizeEstimate? {
        guard data.count <= probeMaxBytes else { return nil }
        do {
            let out = try PDFSanitizer.sanitize(
                data: data,
                options: options,
                compression: profile
            )
            let n = out.count
            // Tiny band so UI can still show a range if wanted; mostly exact
            let pad = max(32, n / 100) // ±1%
            return SizeEstimate(
                bytesLow: max(1, n - pad),
                bytesHigh: n + pad,
                confidence: 0.98,
                method: "exact"
            )
        } catch {
            return nil
        }
    }

    /// Whether a probe is recommended for this input size.
    static func shouldProbe(fileSizeBytes: Int) -> Bool {
        fileSizeBytes > 0 && fileSizeBytes <= probeMaxBytes
    }

    /// Midpoint estimates for levels 0...4, forced non-increasing.
    /// Tuned against measured strip/compress outputs on project fixtures.
    static func midpoints(inventory: PDFSizeInventory) -> [Double] {
        let original = Double(max(1, inventory.fileSizeBytes))
        let image = Double(inventory.imageStreamBytes)
        let meta = Double(inventory.metadataStreamBytes)
        let other = Double(inventory.otherStreamBytes)
        let overhead = Double(inventory.overheadBytes)

        // Level 0: strip + classic rewrite. Usually near original; small files may shrink modestly.
        let stripSaved = meta * 0.95 + original * 0.01
        var level0 = original - stripSaved
        level0 = min(max(level0, original * 0.85), original * 1.06)

        // Only images the lossy levels can re-encode shrink; the rest are carried over as is.
        let shrinkable = min(image, Double(inventory.recompressibleImageBytes ?? inventory.imageStreamBytes))
        let fixedImage = image - shrinkable

        func compose(imageKeep: Double, otherKeep: Double, overheadKeep: Double) -> Double {
            shrinkable * imageKeep
                + fixedImage
                + other * otherKeep
                + meta * 0.02
                + overhead * overheadKeep
        }

        // Rough ratios for re-encoding a high-quality JPEG at each level's quality. How much
        // an image is also scaled down is unknown here, so the band is wide and the measured
        // dry run replaces this figure when the file is small enough to probe.
        let largeImage = shrinkable >= 100_000
        let ik2 = largeImage ? 0.30 : 0.92
        let ik3 = largeImage ? 0.20 : 0.85
        let ik4 = largeImage ? 0.05 : 0.78

        var raw: [Double] = [
            level0,
            compose(imageKeep: 1.00, otherKeep: 0.92, overheadKeep: 0.96), // Light
            compose(imageKeep: ik2, otherKeep: 0.90, overheadKeep: 0.95), // Balanced
            compose(imageKeep: ik3, otherKeep: 0.88, overheadKeep: 0.94), // Strong
            compose(imageKeep: ik4, otherKeep: 0.86, overheadKeep: 0.93), // Maximum
        ]

        if inventory.isTextHeavy {
            // Don't claim huge gains without images
            raw[2] = max(raw[2], level0 * 0.96)
            raw[3] = max(raw[3], level0 * 0.95)
            raw[4] = max(raw[4], level0 * 0.94)
        }

        for i in 1..<raw.count {
            raw[i] = min(raw[i], raw[i - 1] * 0.999)
            raw[i] = max(raw[i], original * 0.001)
            raw[i] = min(raw[i], original * 1.08)
        }
        raw[0] = min(max(raw[0], original * 0.001), original * 1.08)

        for i in 1..<raw.count {
            if raw[i] > raw[i - 1] {
                raw[i] = raw[i - 1] * 0.998
            }
        }
        return raw
    }

    static func textHeavyNote(inventory: PDFSizeInventory, profile: CompressionProfile) -> String? {
        guard inventory.isTextHeavy, profile.id >= 2 else { return nil }
        return "This PDF is mostly text/vectors — compression won’t shrink much."
    }

    /// True if `actual` falls inside estimate band, or within relative slack for heuristics.
    static func actualWithinBand(
        actual: Int,
        estimate: SizeEstimate,
        heuristicSlack: Double = 0.55
    ) -> Bool {
        if actual >= estimate.bytesLow && actual <= estimate.bytesHigh {
            return true
        }
        if estimate.isExact {
            let mid = Double(estimate.bytesMid)
            guard mid > 0 else { return false }
            return abs(Double(actual) - mid) / mid <= 0.05
        }
        let mid = Double(estimate.bytesMid)
        guard mid > 0 else { return false }
        // Also accept if actual sits between half-low and 1.5× high (heuristic uncertainty)
        if actual >= estimate.bytesLow / 2 && actual <= Int(Double(estimate.bytesHigh) * 1.5) {
            return abs(Double(actual) - mid) / mid <= heuristicSlack
                || (actual <= estimate.bytesHigh && actual >= estimate.bytesLow / 2)
        }
        return abs(Double(actual) - mid) / mid <= heuristicSlack
    }
}
