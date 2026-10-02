import Foundation
import Security

/// Document-level and per-object metadata mutations.
/// The stripper only detaches: it removes keys and never deletes the objects they pointed
/// at, because an object can be shared with live content. `PDFReachability.sweep` then drops
/// whatever nothing references any more.
enum PDFStripper {
    /// Apply mutations according to options.
    static func apply(to graph: inout PDFDocumentGraph, options: SanitizeOptions) {
        // Document level
        if options.stripDocumentInfo {
            stripInfo(from: &graph)
        }
        if options.stripCatalogXMP || options.stripDocumentPieceInfo {
            stripCatalogKeys(
                from: &graph,
                removeMetadata: options.stripCatalogXMP,
                removePieceInfo: options.stripDocumentPieceInfo
            )
        }
        if options.regenerateFileID {
            regenerateFileID(on: &graph)
        }

        // Per-object
        if options.stripAllObjectMetadataStreams {
            var keys = ["Metadata"]
            if options.stripDocumentPieceInfo {
                // /LastModified exists only to date the /PieceInfo beside it.
                keys += ["PieceInfo", "LastModified"]
            }
            removeKeysFromEveryObject(keys, in: &graph)
            freeOrphanMetadataStreams(from: &graph)
        }
        if options.stripAnnotationIdentity {
            stripAnnotationIdentity(from: &graph)
        }
        if options.stripEmbeddedImageMetadata {
            scrubEmbeddedJPEGs(from: &graph)
        }
    }

    // MARK: - Info

    private static func stripInfo(from graph: inout PDFDocumentGraph) {
        graph.trailer.removeValue(forKey: "Info")
    }

    // MARK: - Catalog

    private static func stripCatalogKeys(
        from graph: inout PDFDocumentGraph,
        removeMetadata: Bool,
        removePieceInfo: Bool
    ) {
        guard let root = graph.rootRef else { return }
        guard var entry = graph.objects[root.obj] else { return }

        func mutateDict(_ d: inout [String: PDFValue]) {
            if removeMetadata { d.removeValue(forKey: "Metadata") }
            if removePieceInfo { d.removeValue(forKey: "PieceInfo") }
        }

        switch entry.value {
        case .dict(var d):
            mutateDict(&d)
            entry.value = .dict(d)
            graph.objects[root.obj] = entry
        case .stream(var d, let data):
            mutateDict(&d)
            entry.value = .stream(dict: d, data: data)
            graph.objects[root.obj] = entry
        default:
            break
        }
    }

    // MARK: - File ID

    private static func regenerateFileID(on graph: inout PDFDocumentGraph) {
        var a = [UInt8](repeating: 0, count: 16)
        var b = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, a.count, &a) != errSecSuccess {
            for i in 0..<16 { a[i] = UInt8.random(in: 0...255) }
        }
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess {
            for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        }
        graph.trailer["ID"] = .array([
            .hexString(Data(a)),
            .hexString(Data(b)),
        ])
    }

    // MARK: - Keys on every object

    /// Remove `keys` from the dictionary (or stream dictionary) of every object in the graph.
    private static func removeKeysFromEveryObject(_ keys: [String], in graph: inout PDFDocumentGraph) {
        for objNum in Array(graph.objects.keys) {
            guard var entry = graph.objects[objNum] else { continue }
            switch entry.value {
            case .dict(var d):
                var changed = false
                for key in keys where d.removeValue(forKey: key) != nil { changed = true }
                if changed {
                    entry.value = .dict(d)
                    graph.objects[objNum] = entry
                }
            case .stream(var d, let data):
                var changed = false
                for key in keys where d.removeValue(forKey: key) != nil { changed = true }
                if changed {
                    entry.value = .stream(dict: d, data: data)
                    graph.objects[objNum] = entry
                }
            default:
                break
            }
        }
    }

    /// Free remaining objects whose stream/dict is `/Type /Metadata`.
    private static func freeOrphanMetadataStreams(from graph: inout PDFDocumentGraph) {
        let keys = Array(graph.objects.keys)
        for objNum in keys {
            guard let entry = graph.objects[objNum] else { continue }
            let dict: [String: PDFValue]?
            switch entry.value {
            case .dict(let d): dict = d
            case .stream(let d, _): dict = d
            default: dict = nil
            }
            guard let d = dict, case .name(let t) = d["Type"], t == "Metadata" else { continue }
            graph.objects.removeValue(forKey: objNum)
        }
    }

    // MARK: - Annotation identity

    /// Strip author/date identity on annotations; keep content and field names on widgets.
    private static func stripAnnotationIdentity(from graph: inout PDFDocumentGraph) {
        let keys = Array(graph.objects.keys)
        for objNum in keys {
            guard var entry = graph.objects[objNum] else { continue }
            switch entry.value {
            case .dict(var d):
                if mutateAnnotDict(&d) {
                    entry.value = .dict(d)
                    graph.objects[objNum] = entry
                }
            case .stream(var d, let data):
                if mutateAnnotDict(&d) {
                    entry.value = .stream(dict: d, data: data)
                    graph.objects[objNum] = entry
                }
            default:
                break
            }
        }
    }

    /// - Returns: true if dict was modified.
    @discardableResult
    private static func mutateAnnotDict(_ d: inout [String: PDFValue]) -> Bool {
        let isAnnot: Bool = {
            if case .name(let t) = d["Type"], t == "Annot" { return true }
            // Many annots omit /Type but have /Subtype + /Rect
            if d["Subtype"] != nil && d["Rect"] != nil { return true }
            return false
        }()
        guard isAnnot else { return false }

        let isWidget: Bool = {
            if case .name(let s) = d["Subtype"], s == "Widget" { return true }
            return false
        }()

        var changed = false
        // Dates always go
        for key in ["M", "CreationDate"] {
            if d.removeValue(forKey: key) != nil { changed = true }
        }
        // /T is author on markup annots; field name on widgets — keep widgets
        if !isWidget {
            if d.removeValue(forKey: "T") != nil { changed = true }
        }
        // Optional identity-ish keys (safe to drop on markup)
        if !isWidget {
            for key in ["NM", "RC", "DS", "Subj"] {
                if d.removeValue(forKey: key) != nil { changed = true }
            }
        }
        return changed
    }

    // MARK: - JPEG scrub

    private static func scrubEmbeddedJPEGs(from graph: inout PDFDocumentGraph) {
        let keys = Array(graph.objects.keys)
        for objNum in keys {
            guard var entry = graph.objects[objNum] else { continue }
            guard case .stream(var dict, let data) = entry.value else { continue }
            guard ImageMetadataStripper.isDCTDecode(dict) else { continue }
            let scrubbed = ImageMetadataStripper.scrubJPEGIfNeeded(data)
            if scrubbed != data {
                dict["Length"] = .int(scrubbed.count)
                // Drop decode params that might assume old layout (rare for DCT)
                entry.value = .stream(dict: dict, data: scrubbed)
                graph.objects[objNum] = entry
            }
        }
    }

}
