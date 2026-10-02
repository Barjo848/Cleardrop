import Foundation

// MARK: - Errors

enum PDFSanitizerError: LocalizedError, Equatable {
    case notPDF
    case cannotRead
    case encrypted
    case signed
    case corrupt(String)
    case unsupportedStructure(String)
    case oversize(limitMB: Int)
    case cannotWrite(URL)
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .notPDF: return "Not a PDF."
        case .cannotRead: return "Could not read that PDF."
        case .encrypted: return "PDF is password-protected."
        case .signed: return "Signed PDFs are not modified."
        case .corrupt: return "This PDF is damaged or incomplete."
        case .unsupportedStructure: return "This PDF uses a structure Cleardrop can’t read."
        case .oversize: return "PDF is too large."
        case .cannotWrite: return "Could not save the cleaned PDF."
        case .emptyInput: return "Not a PDF."
        }
    }
}

// MARK: - Options

struct SanitizeOptions: Sendable, Equatable {
    var stripDocumentInfo: Bool = true
    var stripCatalogXMP: Bool = true
    var regenerateFileID: Bool = true
    var stripDocumentPieceInfo: Bool = true
    /// Annotation `/T` (markup author), `/M`, `/CreationDate`, …
    var stripAnnotationIdentity: Bool = true
    /// Scrub APP1/APP13 from DCTDecode JPEG streams.
    var stripEmbeddedImageMetadata: Bool = true
    /// Remove `/Metadata` on every object (pages, XObjects, …).
    var stripAllObjectMetadataStreams: Bool = true
    var failIfEncrypted: Bool = true
    var failIfSigned: Bool = true
    /// Parse and write only, no strip. Used by tests to isolate the round-trip.
    var identityRewrite: Bool = false

    /// Production default: document-level and per-object strip.
    static let `default` = SanitizeOptions()

    /// Document level only — no page Metadata / EXIF / annotation identity.
    static let documentLevelOnly = SanitizeOptions(
        stripAnnotationIdentity: false,
        stripEmbeddedImageMetadata: false,
        stripAllObjectMetadataStreams: false
    )

    /// Classic-xref identity round-trip.
    static let identityRewriteOnly = SanitizeOptions(
        stripDocumentInfo: false,
        stripCatalogXMP: false,
        regenerateFileID: false,
        stripDocumentPieceInfo: false,
        stripAnnotationIdentity: false,
        stripEmbeddedImageMetadata: false,
        stripAllObjectMetadataStreams: false,
        identityRewrite: true
    )
}

// MARK: - Inspection

/// One human-readable metadata finding for the review UI.
struct MetadataFinding: Sendable, Equatable, Identifiable {
    var id: String { "\(category)|\(label)|\(value ?? "")" }
    var category: String
    var label: String
    var value: String?
}

struct PDFInspection: Sendable, Equatable {
    var pageCount: Int
    var isEncrypted: Bool
    var isSigned: Bool
    var hasInfoDict: Bool
    var hasCatalogXMP: Bool
    var hasOtherMetadataStreams: Bool
    var producer: String?
    var author: String?
    var title: String?
    var creator: String?
    var subject: String?
    var keywords: String?
    var creationDate: String?
    var modDate: String?
    var hasEmbeddedFiles: Bool
    var hasJS: Bool
    var hasICC: Bool
    var hasTrailerFileID: Bool
    var hasPieceInfo: Bool
    var annotationIdentityCount: Int
    var jpegWithAppMetadataCount: Int
    var fileSizeBytes: Int
    /// Signature fields that exist but have not been signed. They are kept.
    var emptySignatureFieldCount: Int = 0
    /// Images in the saved document, and how many the lossy levels are able to re-encode.
    var imageCount: Int = 0
    var recompressibleImageCount: Int = 0
    /// Rows shown to the user before clearing: what will be removed, plus security notes.
    var findings: [MetadataFinding]
    /// Things Cleardrop detects and does not remove. They are still in the saved copy.
    var residuals: [MetadataFinding] = []
    /// Stream/byte inventory for compression estimates.
    var sizeInventory: PDFSizeInventory

    /// True if Cleardrop can strip something useful.
    var hasStrippableMetadata: Bool {
        !findings.isEmpty
    }

    static func emptyEncrypted(fileSize: Int) -> PDFInspection {
        PDFInspection(
            pageCount: 0,
            isEncrypted: true,
            isSigned: false,
            hasInfoDict: false,
            hasCatalogXMP: false,
            hasOtherMetadataStreams: false,
            producer: nil,
            author: nil,
            title: nil,
            creator: nil,
            subject: nil,
            keywords: nil,
            creationDate: nil,
            modDate: nil,
            hasEmbeddedFiles: false,
            hasJS: false,
            hasICC: false,
            hasTrailerFileID: false,
            hasPieceInfo: false,
            annotationIdentityCount: 0,
            jpegWithAppMetadataCount: 0,
            fileSizeBytes: fileSize,
            findings: [
                MetadataFinding(category: "Security", label: "Encryption", value: "Password-protected"),
            ],
            sizeInventory: PDFSizeInventory(
                imageStreamBytes: 0,
                metadataStreamBytes: 0,
                otherStreamBytes: 0,
                fileSizeBytes: fileSize
            )
        )
    }
}

// MARK: - Engine

/// Pure engine — no SwiftUI. UI calls via `Task.detached`.
enum PDFSanitizer {
    static let maxInputBytes: Int = 100 * 1024 * 1024
    static let maxObjectCount: Int = 500_000
    /// Total bytes the parser may inflate from cross-reference and object streams in one file.
    static let maxInflatedBytes: Int = 256 * 1024 * 1024

    /// Test-only overrides (nil = production limits).
    static var testMaxInputBytes: Int?
    static var testMaxObjectCount: Int?
    static var testMaxInflatedBytes: Int?

    static var effectiveMaxInflatedBytes: Int {
        testMaxInflatedBytes ?? maxInflatedBytes
    }

    static var effectiveMaxInputBytes: Int {
        testMaxInputBytes ?? maxInputBytes
    }

    static var effectiveMaxObjectCount: Int {
        testMaxObjectCount ?? maxObjectCount
    }

    private static let pdfMagic = Data("%PDF-".utf8)

    // MARK: Public API

    /// Validate, sanitize, write to a caller-chosen destination URL.
    /// Refuses a destination that is the source file: the original is never overwritten.
    @discardableResult
    static func process(
        from sourceURL: URL,
        to destinationURL: URL,
        options: SanitizeOptions = .default,
        compression: CompressionProfile = CompressionProfiles.profile(for: 0)
    ) throws -> ExportReport {
        if isSameFile(sourceURL, destinationURL) {
            throw PDFSanitizerError.cannotWrite(destinationURL)
        }
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw PDFSanitizerError.cannotRead
        }
        let result = try sanitizeWithReport(data: data, options: options, compression: compression)
        do {
            try result.data.write(to: destinationURL, options: .atomic)
        } catch {
            throw PDFSanitizerError.cannotWrite(destinationURL)
        }
        return result.report
    }

    /// In-memory transform (strip + optional compression profile).
    static func sanitize(
        data: Data,
        options: SanitizeOptions = .default,
        compression: CompressionProfile = CompressionProfiles.profile(for: 0)
    ) throws -> Data {
        try sanitizeWithReport(data: data, options: options, compression: compression).data
    }

    /// The transform, plus a report built by inspecting the bytes it produced.
    static func sanitizeWithReport(
        data: Data,
        options: SanitizeOptions = .default,
        compression: CompressionProfile = CompressionProfiles.profile(for: 0)
    ) throws -> (data: Data, report: ExportReport) {
        try validatePDF(data: data)
        return try structuralPipeline(data: data, options: options, compression: compression)
    }

    /// Parse + inspect without writing. Builds human-readable `findings` for the review UI.
    static func inspect(data: Data) throws -> PDFInspection {
        try validatePDF(data: data)
        let graph: PDFDocumentGraph
        do {
            graph = try PDFParser.parse(data)
        } catch PDFSanitizerError.encrypted {
            return .emptyEncrypted(fileSize: data.count)
        }
        let pages = try requirePages(graph)
        return buildInspection(graph: graph, pageCount: pages, fileSizeBytes: data.count)
    }

    /// The page tree must be walkable and hold at least one page. A file that fails this is
    /// refused: rewriting it would produce a document with no pages.
    static func requirePages(_ graph: PDFDocumentGraph) throws -> Int {
        guard let pages = PDFGraphInspect.pageCount(graph) else {
            throw PDFSanitizerError.corrupt("page tree cannot be followed")
        }
        guard pages > 0 else {
            throw PDFSanitizerError.corrupt("no pages")
        }
        return pages
    }

    static func inspect(url: URL) throws -> PDFInspection {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PDFSanitizerError.cannotRead
        }
        return try inspect(data: data)
    }

    private static func buildInspection(
        graph: PDFDocumentGraph,
        pageCount: Int,
        fileSizeBytes: Int
    ) -> PDFInspection {
        let signed = PDFSignatureDetector.looksSigned(graph)
        let info = PDFGraphInspect.infoDictionary(graph)
        let author = PDFGraphInspect.stringValue(info?["Author"])
        let title = PDFGraphInspect.stringValue(info?["Title"])
        let subject = PDFGraphInspect.stringValue(info?["Subject"])
        let keywords = PDFGraphInspect.stringValue(info?["Keywords"])
        let creator = PDFGraphInspect.stringValue(info?["Creator"])
        let producer = PDFGraphInspect.stringValue(info?["Producer"])
        let creationDate = PDFGraphInspect.stringValue(info?["CreationDate"])
        let modDate = PDFGraphInspect.stringValue(info?["ModDate"])
        let hasInfo = PDFGraphInspect.hasInfoDict(graph)
        let catalogXMP = PDFGraphInspect.catalogHasMetadata(graph)
        let otherMeta = PDFGraphInspect.hasMetadataOutsideCatalog(graph)
        let trailerID = PDFGraphInspect.hasTrailerFileID(graph)
        let piece = PDFGraphInspect.hasPieceInfo(graph)
        let annotCount = PDFGraphInspect.annotationIdentityCount(graph)
        let jpegCount = PDFGraphInspect.jpegWithAppMetadataCount(graph)

        var findings: [MetadataFinding] = []

        func add(_ category: String, _ label: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                findings.append(MetadataFinding(category: category, label: label, value: trimmed))
            }
        }
        func addFlag(_ category: String, _ label: String, _ present: Bool, value: String = "Present") {
            if present {
                findings.append(MetadataFinding(category: category, label: label, value: value))
            }
        }

        add("Document info", "Title", title)
        add("Document info", "Author", author)
        add("Document info", "Subject", subject)
        add("Document info", "Keywords", keywords)
        add("Document info", "Creator", creator)
        add("Document info", "Producer", producer)
        add("Document info", "Creation date", creationDate)
        add("Document info", "Modification date", modDate)

        // Other Info keys (custom)
        if let info {
            let known: Set<String> = [
                "Title", "Author", "Subject", "Keywords", "Creator", "Producer",
                "CreationDate", "ModDate", "Trapped",
            ]
            for key in info.keys.sorted() where !known.contains(key) {
                if let v = PDFGraphInspect.stringValue(info[key]), !v.isEmpty {
                    add("Document info", key, v)
                } else {
                    addFlag("Document info", key, true, value: "(non-text value)")
                }
            }
            // Info exists but all standard fields empty
            if findings.filter({ $0.category == "Document info" }).isEmpty && hasInfo {
                addFlag("Document info", "Info dictionary", true, value: "Present (empty fields)")
            }
        }

        addFlag("XMP / streams", "Catalog XMP metadata", catalogXMP)
        addFlag("XMP / streams", "Page or object XMP metadata", otherMeta)
        addFlag("XMP / streams", "Application private data (PieceInfo)", piece)
        addFlag("File identity", "Trailer file ID", trailerID, value: "Links copies of this file; replaced with a random one")
        if annotCount > 0 {
            findings.append(MetadataFinding(
                category: "Annotations",
                label: "Annotation authors / dates",
                value: "\(annotCount) annotation\(annotCount == 1 ? "" : "s")"
            ))
        }
        if jpegCount > 0 {
            findings.append(MetadataFinding(
                category: "Images",
                label: "JPEG EXIF / XMP / IPTC",
                value: "\(jpegCount) image stream\(jpegCount == 1 ? "" : "s")"
            ))
        }
        if signed {
            findings.append(MetadataFinding(
                category: "Security",
                label: "Digital signature",
                value: "Detected — Cleardrop will not modify this file"
            ))
        }

        // What stays is judged on the document as it will be saved: metadata detached and
        // unreferenced objects dropped. Something only the Info dictionary pointed at, for
        // example, is going away and must not be listed as staying.
        var kept = graph
        var simulation = SanitizeOptions.default
        simulation.stripEmbeddedImageMetadata = false
        simulation.regenerateFileID = false
        PDFStripper.apply(to: &kept, options: simulation)
        PDFReachability.sweep(&kept)

        let hasJS = PDFGraphInspect.hasJavaScript(kept)
        let hasEmbedded = PDFGraphInspect.hasEmbeddedFiles(kept)
        let hasICC = PDFGraphInspect.hasICC(kept)
        let emptySignatureFields = signed ? 0 : PDFSignatureDetector.emptySignatureFieldCount(kept)

        var residuals: [MetadataFinding] = []
        func addResidual(_ label: String, _ value: String) {
            residuals.append(MetadataFinding(category: ReviewSummary.residualCategory, label: label, value: value))
        }
        if hasJS {
            addResidual("JavaScript", "Scripts are not removed")
        }
        if hasEmbedded {
            addResidual("Attached files", "Attachments and their contents are not removed")
        }
        if hasICC {
            addResidual("Color profiles", "ICC profiles and output intents are not removed")
        }
        if emptySignatureFields > 0 {
            addResidual(
                "Empty signature field",
                "\(emptySignatureFields) unsigned field\(emptySignatureFields == 1 ? "" : "s"), kept as is"
            )
        }

        let images = ImageRecompressor.imageCounts(in: kept)
        let inventory = PDFSizeInventory.from(graph: graph, fileSizeBytes: fileSizeBytes)

        return PDFInspection(
            pageCount: pageCount,
            isEncrypted: graph.isEncrypted,
            isSigned: signed,
            hasInfoDict: hasInfo,
            hasCatalogXMP: catalogXMP,
            hasOtherMetadataStreams: otherMeta,
            producer: producer,
            author: author,
            title: title,
            creator: creator,
            subject: subject,
            keywords: keywords,
            creationDate: creationDate,
            modDate: modDate,
            hasEmbeddedFiles: hasEmbedded,
            hasJS: hasJS,
            hasICC: hasICC,
            hasTrailerFileID: trailerID,
            hasPieceInfo: piece,
            annotationIdentityCount: annotCount,
            jpegWithAppMetadataCount: jpegCount,
            fileSizeBytes: fileSizeBytes,
            emptySignatureFieldCount: emptySignatureFields,
            imageCount: images.total,
            recompressibleImageCount: images.eligible,
            findings: findings,
            residuals: residuals,
            sizeInventory: inventory
        )
    }

    static func validatePDF(data: Data) throws {
        if data.isEmpty {
            throw PDFSanitizerError.emptyInput
        }
        let limit = effectiveMaxInputBytes
        if data.count > limit {
            let mb = max(1, limit / (1024 * 1024))
            throw PDFSanitizerError.oversize(limitMB: mb)
        }
        guard data.starts(with: pdfMagic) else {
            throw PDFSanitizerError.notPDF
        }
    }

    /// Parse → encrypt/sign checks → strip → optional compression → write classic xref.
    static func structuralPipeline(
        data: Data,
        options: SanitizeOptions,
        compression: CompressionProfile = CompressionProfiles.profile(for: 0)
    ) throws -> (data: Data, report: ExportReport) {
        var graph = try PDFParser.parse(data)

        if options.failIfEncrypted && graph.isEncrypted {
            throw PDFSanitizerError.encrypted
        }
        if options.failIfSigned && PDFSignatureDetector.looksSigned(graph) {
            throw PDFSanitizerError.signed
        }
        let pagesIn = try requirePages(graph)
        let before = buildInspection(graph: graph, pageCount: pagesIn, fileSizeBytes: data.count)

        var outcome = PDFCompressor.Outcome()
        if !options.identityRewrite {
            PDFStripper.apply(to: &graph, options: options)
            // Only what the trailer still reaches is kept, so detached metadata, superseded
            // revisions and stray objects are not carried into the output.
            PDFReachability.sweep(&graph)
            // Lossless / lossy compression after strip.
            outcome = PDFCompressor.apply(to: &graph, profile: compression)
        }

        let out = try PDFWriter.write(graph)

        // Read the result back before handing it over. If the page count moved, something in
        // the pipeline lost part of the document, and no output is better than that output.
        let written = try PDFParser.parse(out)
        guard PDFGraphInspect.pageCount(written) == pagesIn else {
            throw PDFSanitizerError.corrupt("page count changed during rewrite")
        }
        // The report describes the bytes that were produced, not what the pipeline intended.
        let after = buildInspection(graph: written, pageCount: pagesIn, fileSizeBytes: out.count)
        let report = ExportReport.make(
            before: before, after: after, compressionLevel: compression.id, compression: outcome
        )
        return (out, report)
    }

    // MARK: Internals

    /// True when both URLs resolve to the same file on disk (through symlinks or hard links).
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let ra = a.resolvingSymlinksInPath().standardizedFileURL
        let rb = b.resolvingSymlinksInPath().standardizedFileURL
        if ra.path == rb.path { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ia = try? ra.resourceValues(forKeys: keys).fileResourceIdentifier,
              let ib = try? rb.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return ia.isEqual(ib)
    }
}
