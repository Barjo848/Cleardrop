import Foundation

/// Everything the review screen says, decided here so it can be tested. The window only
/// lays these strings out.
struct ReviewSummary: Sendable, Equatable {
    static let residualCategory = "Stays in the file"
    static let removableHeading = "WILL BE REMOVED"
    static let residualHeading = "STAYS IN THE FILE"

    /// Shown on every review, whatever the file contains.
    static let standingNote =
        "Page text, images and fonts are not changed. If what is on the pages identifies you, the cleaned copy still does."

    static let emptyTitle = "No removable metadata found"
    static let emptyBody =
        "Cleardrop looked for document info, XMP metadata, a file ID, private application data, annotation authors and dates, and JPEG metadata, and found none. You can still save a rewritten copy."

    /// Findings the save will remove or replace.
    var removable: [MetadataFinding]
    /// Things detected that the save leaves in place.
    var residual: [MetadataFinding]
    var isSigned: Bool
    var pageCount: Int
    var imageCount: Int
    var recompressibleImageCount: Int

    init(_ inspection: PDFInspection) {
        removable = inspection.findings.filter { $0.category != "Security" }
        residual = inspection.residuals
        isSigned = inspection.isSigned
        pageCount = inspection.pageCount
        imageCount = inspection.imageCount
        recompressibleImageCount = inspection.recompressibleImageCount
    }

    /// For the lossy levels: how much of this particular file they can act on.
    func compressionScopeNote(for profile: CompressionProfile) -> String? {
        guard profile.isLossy else { return nil }
        if imageCount == 0 {
            return "This PDF has no images, so this level does nothing more than Light."
        }
        if recompressibleImageCount == 0 {
            return "None of the \(imageCount) image\(imageCount == 1 ? "" : "s") in this PDF can be re-encoded, so this level does nothing more than Light."
        }
        return "\(recompressibleImageCount) of \(imageCount) image\(imageCount == 1 ? "" : "s") in this PDF can be re-encoded."
    }

    /// One line under the file name.
    var summaryLine: String {
        let pages = "\(pageCount) page\(pageCount == 1 ? "" : "s")"
        if isSigned {
            return "\(pages) · signed"
        }
        if removable.isEmpty {
            return "\(pages) · no removable metadata found"
        }
        return "\(pages) · \(removable.count) metadata item\(removable.count == 1 ? "" : "s") to remove"
    }

    /// One line naming everything detected that the save leaves in place. Shown outside the
    /// scrolling list so it cannot be missed. `nil` when nothing was detected.
    var residualLine: String? {
        guard !residual.isEmpty else { return nil }
        return "Stays in the file: \(residual.map(\.label).joined(separator: ", "))."
    }

    /// The primary button. It names what will happen and nothing more.
    func actionTitle(for profile: CompressionProfile) -> String {
        let level = CompressionProfiles.clamp(profile.id)
        let removes = !removable.isEmpty
        switch (level, removes) {
        case (0, true): return "Remove metadata and save…"
        case (0, false): return "Save a rewritten copy…"
        case (1, true): return "Remove metadata, pack and save…"
        case (1, false): return "Pack and save…"
        case (_, true): return "Remove metadata, compress and save…"
        case (_, false): return "Compress and save…"
        }
    }
}

/// What a save actually did, worked out by inspecting the file that was written.
struct ExportReport: Sendable, Equatable {
    /// Findings present in the original and absent from the saved copy.
    var removed: [MetadataFinding]
    /// True when the original had a file ID, which the saved copy replaces with a random one.
    var replacedFileID: Bool
    /// Removable findings that are still present in the saved copy. Expected to be empty.
    var leftBehind: [MetadataFinding]
    /// Things that were never going to be removed and are in the saved copy.
    var stillPresent: [MetadataFinding]
    var compressionLevel: Int
    var imagesRecompressed: Int
    var imageCount: Int
    var streamsPacked: Int
    var bytesBefore: Int
    var bytesAfter: Int

    private static let fileIDLabel = "Trailer file ID"

    static func make(
        before: PDFInspection,
        after: PDFInspection,
        compressionLevel: Int,
        compression: PDFCompressor.Outcome = PDFCompressor.Outcome()
    ) -> ExportReport {
        func key(_ finding: MetadataFinding) -> String { "\(finding.category)|\(finding.label)" }
        let beforeRows = before.findings.filter { $0.category != "Security" }
        let afterRows = after.findings.filter { $0.category != "Security" }
        let afterKeys = Set(afterRows.map(key))

        let removed = beforeRows.filter { $0.label != fileIDLabel && !afterKeys.contains(key($0)) }
        let leftBehind = afterRows.filter { $0.label != fileIDLabel }
        return ExportReport(
            removed: removed,
            replacedFileID: before.hasTrailerFileID,
            leftBehind: leftBehind,
            stillPresent: after.residuals,
            compressionLevel: compressionLevel,
            imagesRecompressed: compression.imagesRecompressed,
            imageCount: before.imageCount,
            streamsPacked: compression.streamsPacked,
            bytesBefore: before.fileSizeBytes,
            bytesAfter: after.fileSizeBytes
        )
    }

    /// Number of things removed or replaced.
    var changeCount: Int {
        removed.count + (replacedFileID ? 1 : 0)
    }

    /// The sentence on the done screen.
    var message: String {
        var parts: [String] = []
        if changeCount == 0 {
            parts.append("No metadata was found to remove; this is a rewritten copy.")
        } else {
            parts.append("Removed \(changeCount) metadata item\(changeCount == 1 ? "" : "s") from this copy.")
        }
        if !leftBehind.isEmpty {
            parts.append("\(leftBehind.count) item\(leftBehind.count == 1 ? " is" : "s are") still present: \(leftBehind.map(\.label).joined(separator: ", ")).")
        }
        if compressionLevel > 0 {
            if imagesRecompressed == 0 && streamsPacked == 0 {
                parts.append("Compression found nothing it could shrink in this file.")
            } else {
                var did: [String] = []
                if imagesRecompressed > 0 {
                    did.append("re-encoded \(imagesRecompressed) of \(imageCount) image\(imageCount == 1 ? "" : "s")")
                }
                if streamsPacked > 0 {
                    did.append("packed \(streamsPacked) uncompressed stream\(streamsPacked == 1 ? "" : "s")")
                }
                parts.append("Compression \(did.joined(separator: " and ")).")
            }
            if bytesAfter < bytesBefore {
                parts.append("The file went from \(ByteSizeFormat.string(bytes: bytesBefore)) to \(ByteSizeFormat.string(bytes: bytesAfter)).")
            } else {
                parts.append("The saved copy is not smaller than the original.")
            }
        }
        if !stillPresent.isEmpty {
            parts.append("Still in the file: \(stillPresent.map(\.label).joined(separator: ", ")).")
        }
        parts.append("Your original file was not changed.")
        return parts.joined(separator: " ")
    }
}
