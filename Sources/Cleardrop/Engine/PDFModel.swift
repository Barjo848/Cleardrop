import Foundation

// MARK: - PDF object graph (classic-xref subset)

/// Indirect reference `n g R`.
struct PDFRef: Hashable, Sendable, Comparable {
    var obj: Int
    var gen: Int

    static func < (lhs: PDFRef, rhs: PDFRef) -> Bool {
        if lhs.obj != rhs.obj { return lhs.obj < rhs.obj }
        return lhs.gen < rhs.gen
    }
}

/// PDF names are byte sequences, not text. They are held as a `String` with one scalar per
/// byte (U+0000…U+00FF), so ASCII names compare as usual and every other byte survives a
/// round trip unchanged.
enum PDFName {
    static func string(fromBytes bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    static func bytes(of name: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in name.unicodeScalars {
            if scalar.value <= 0xFF {
                out.append(UInt8(scalar.value))
            } else {
                // A name built in code from text outside Latin-1: fall back to its UTF-8 bytes.
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return out
    }
}

/// One in-memory PDF value. Streams keep **raw** payload bytes (filters untouched).
enum PDFValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)          // without leading '/'; see `PDFName`
    case string(Data)          // literal string content bytes
    case hexString(Data)
    case ref(PDFRef)
    case array([PDFValue])
    case dict([String: PDFValue]) // keys without leading '/'
    case stream(dict: [String: PDFValue], data: Data)
}

/// Free or live xref entry.
struct PDFXRefEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case free
        case inUse(offset: Int)
        /// Stored inside object stream number `stream`, at position `index`.
        case compressed(stream: Int, index: Int)
    }
    var gen: Int
    var kind: Kind
}

/// Parsed document graph. Object numbers are **stable** (no compact renumber).
struct PDFDocumentGraph: Sendable {
    var versionMajor: Int
    var versionMinor: Int
    /// Live objects only (obj num → value). Free numbers omitted.
    var objects: [Int: (gen: Int, value: PDFValue)]
    /// Trailer dictionary (without stream).
    var trailer: [String: PDFValue]
    /// Highest object number + 1 candidate from trailer /Size or max key.
    var size: Int

    var rootRef: PDFRef? {
        guard case .ref(let r) = trailer["Root"] else { return nil }
        return r
    }

    var isEncrypted: Bool {
        trailer["Encrypt"] != nil
    }

    /// Resolve a direct int, or int object, from a value (e.g. stream /Length).
    func intValue(_ value: PDFValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let n): return n
        case .ref(let r):
            guard let entry = objects[r.obj], entry.gen == r.gen else { return nil }
            if case .int(let n) = entry.value { return n }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Signature / structure walk

enum PDFSignatureDetector {
    /// Conservative over-approximation: if unsure, treat as signed.
    /// A signature *field* that nobody has signed (`/FT /Sig` with no `/V`) is not a
    /// signature; see `emptySignatureFieldCount`.
    static func looksSigned(_ graph: PDFDocumentGraph) -> Bool {
        if looksSignedValue(.dict(graph.trailer)) { return true }
        for (_, entry) in graph.objects {
            if looksSignedValue(entry.value) { return true }
        }
        // Certification or usage-rights entries on the catalog, direct or as an object.
        if let root = graph.rootRef,
           let catalog = graph.objects[root.obj].flatMap({ PDFGraphInspect.dict(of: $0.value) }),
           var perms = catalog["Perms"]
        {
            if case .ref(let ref) = perms, let target = graph.objects[ref.obj]?.value {
                perms = target
            }
            if let d = PDFGraphInspect.dict(of: perms), !d.isEmpty { return true }
        }
        return false
    }

    /// Signature fields that are present but unsigned.
    static func emptySignatureFieldCount(_ graph: PDFDocumentGraph) -> Int {
        var count = 0
        for (_, entry) in graph.objects {
            guard let d = PDFGraphInspect.dict(of: entry.value),
                  case .some(.name(let type)) = d["FT"], type == "Sig",
                  !hasValue(d["V"])
            else { continue }
            count += 1
        }
        return count
    }

    private static func hasValue(_ value: PDFValue?) -> Bool {
        switch value {
        case nil, .some(.null): return false
        default: return true
        }
    }

    private static func looksSignedValue(_ value: PDFValue) -> Bool {
        switch value {
        case .dict(let d), .stream(let d, _):
            if dictLooksSigned(d) { return true }
            for (_, v) in d {
                if looksSignedValue(v) { return true }
            }
            return false
        case .array(let a):
            return a.contains { looksSignedValue($0) }
        default:
            return false
        }
    }

    private static func dictLooksSigned(_ d: [String: PDFValue]) -> Bool {
        // /Type /Sig
        if case .name(let t) = d["Type"], t == "Sig" { return true }
        // /FT /Sig with a value: a signature field that has been signed.
        if case .name(let ft) = d["FT"], ft == "Sig", hasValue(d["V"]) { return true }
        // ByteRange is nearly always a signature dictionary
        if d["ByteRange"] != nil {
            if d["Contents"] != nil { return true }
            if d["Filter"] != nil { return true }
        }
        // PKCS#7 filters
        if let filterName = nameOrString(d["Filter"]) {
            let f = filterName.lowercased()
            if f.contains("adbe.pkcs7")
                || f.contains("adobe.ppklite")
                || f.contains("adobe.ppkms")
                || f.contains("adobe.ppkms")
            {
                return true
            }
        }
        // DocMDP / certification in Perms
        if case .dict(let perms) = d["Perms"] {
            if perms["DocMDP"] != nil || perms["UR"] != nil || perms["UR3"] != nil {
                return true
            }
        }
        if d["DocMDP"] != nil { return true }
        return false
    }

    private static func nameOrString(_ v: PDFValue?) -> String? {
        guard let v else { return nil }
        switch v {
        case .name(let n): return n
        case .string(let data): return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        case .hexString(let data): return String(data: data, encoding: .ascii)
        default: return nil
        }
    }
}

// MARK: - Residual / inspect helpers

enum PDFGraphInspect {
    /// Number of page objects found by walking the page tree from the catalog.
    /// `nil` when the tree cannot be followed: no catalog, a missing or non-dictionary node,
    /// or a node reached twice. The `/Count` entries are not trusted.
    static func pageCount(_ graph: PDFDocumentGraph) -> Int? {
        guard let root = graph.rootRef,
              let rootObj = graph.objects[root.obj]?.value,
              let catalog = dict(of: rootObj),
              case .ref(let pagesRef) = catalog["Pages"]
        else { return nil }

        var count = 0
        var visited = Set<Int>()
        var pending = [pagesRef]
        while let ref = pending.popLast() {
            guard visited.insert(ref.obj).inserted,
                  let value = graph.objects[ref.obj]?.value,
                  let node = dict(of: value)
            else { return nil }

            var kidsValue = node["Kids"]
            if case .ref(let kidsRef) = kidsValue {
                kidsValue = graph.objects[kidsRef.obj]?.value
            }
            if case .name(let type) = node["Type"], type == "Page" {
                count += 1
            } else if case .array(let kids) = kidsValue {
                for kid in kids {
                    guard case .ref(let kidRef) = kid else { return nil }
                    pending.append(kidRef)
                }
            } else if node["Kids"] == nil {
                // A leaf without /Type is still a page to every reader.
                count += 1
            } else {
                return nil
            }
        }
        return count
    }

    static func unwrapStreamDict(_ v: PDFValue) -> PDFValue {
        if case .stream(let d, _) = v { return .dict(d) }
        return v
    }

    static func dict(of value: PDFValue) -> [String: PDFValue]? {
        switch value {
        case .dict(let d): return d
        case .stream(let d, _): return d
        default: return nil
        }
    }

    static func hasInfoDict(_ graph: PDFDocumentGraph) -> Bool {
        graph.trailer["Info"] != nil
    }

    static func catalogHasMetadata(_ graph: PDFDocumentGraph) -> Bool {
        guard let root = graph.rootRef,
              let rootObj = graph.objects[root.obj]?.value,
              let catalog = dict(of: rootObj)
        else { return false }
        return catalog["Metadata"] != nil
    }

    /// Any remaining `/Metadata` key on any live object.
    static func hasAnyMetadataKey(_ graph: PDFDocumentGraph) -> Bool {
        for (_, entry) in graph.objects {
            if let d = dict(of: entry.value), d["Metadata"] != nil { return true }
        }
        return false
    }

    /// `/Metadata` on an object other than the catalog (page / XObject / …).
    static func hasMetadataOutsideCatalog(_ graph: PDFDocumentGraph) -> Bool {
        let rootNum = graph.rootRef?.obj
        for (num, entry) in graph.objects {
            if num == rootNum { continue }
            if let d = dict(of: entry.value), d["Metadata"] != nil { return true }
        }
        return false
    }

    static func hasEmbeddedFiles(_ graph: PDFDocumentGraph) -> Bool {
        for (_, entry) in graph.objects {
            guard let d = dict(of: entry.value) else { continue }
            if d["EF"] != nil || d["F"] != nil && d["Type"] != nil {
                if case .name(let t) = d["Type"], t == "Filespec" || t == "FileSpec" { return true }
            }
            if case .name(let t) = d["Type"], t == "EmbeddedFile" { return true }
            if d["EmbeddedFiles"] != nil { return true }
        }
        // Names tree on catalog
        if let root = graph.rootRef,
           let rootObj = graph.objects[root.obj]?.value,
           let catalog = dict(of: rootObj),
           case .dict(let names) = catalog["Names"],
           names["EmbeddedFiles"] != nil
        {
            return true
        }
        return false
    }

    static func hasJavaScript(_ graph: PDFDocumentGraph) -> Bool {
        for (_, entry) in graph.objects {
            guard let d = dict(of: entry.value) else { continue }
            if case .name(let s) = d["S"], s == "JavaScript" { return true }
            if d["JS"] != nil { return true }
        }
        return false
    }

    static func hasICC(_ graph: PDFDocumentGraph) -> Bool {
        for (_, entry) in graph.objects {
            guard let d = dict(of: entry.value) else { continue }
            if case .name(let t) = d["Type"], t == "OutputIntent" { return true }
            if case .array(let a) = d["ColorSpace"],
               let first = a.first, case .name(let n) = first, n == "ICCBased"
            {
                return true
            }
            // Color space object itself: [/ICCBased <<...>>]
            if case .array(let a) = entry.value,
               let first = a.first, case .name(let n) = first, n == "ICCBased"
            {
                return true
            }
        }
        return false
    }

    // MARK: Detailed inspection helpers

    /// Resolve trailer `/Info` dictionary if present.
    static func infoDictionary(_ graph: PDFDocumentGraph) -> [String: PDFValue]? {
        guard let infoVal = graph.trailer["Info"] else { return nil }
        switch infoVal {
        case .dict(let d):
            return d
        case .ref(let r):
            guard let entry = graph.objects[r.obj] else { return nil }
            return dict(of: entry.value)
        default:
            return nil
        }
    }

    static func stringValue(_ value: PDFValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let data):
            return decodePDFString(data)
        case .hexString(let data):
            return decodePDFString(data)
        case .name(let n):
            return n
        case .int(let n):
            return String(n)
        case .real(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        default:
            return nil
        }
    }

    private static func decodePDFString(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    /// Count markup-like annotations that carry identity fields.
    static func annotationIdentityCount(_ graph: PDFDocumentGraph) -> Int {
        var count = 0
        for (_, entry) in graph.objects {
            guard let d = dict(of: entry.value) else { continue }
            let isAnnot: Bool = {
                if case .name(let t) = d["Type"], t == "Annot" { return true }
                return d["Subtype"] != nil && d["Rect"] != nil
            }()
            guard isAnnot else { continue }
            let isWidget: Bool = {
                if case .name(let s) = d["Subtype"], s == "Widget" { return true }
                return false
            }()
            if isWidget { continue }
            if d["T"] != nil || d["M"] != nil || d["CreationDate"] != nil {
                count += 1
            }
        }
        return count
    }

    /// Count DCTDecode streams that look like they contain JPEG APP metadata.
    static func jpegWithAppMetadataCount(_ graph: PDFDocumentGraph) -> Int {
        var count = 0
        for (_, entry) in graph.objects {
            guard case .stream(let dict, let data) = entry.value else { continue }
            guard ImageMetadataStripper.isDCTDecode(dict) else { continue }
            if jpegHasIdentityAPP(data) { count += 1 }
        }
        return count
    }

    /// True exactly when the scrubber would remove something, so the review screen and the
    /// save agree. A byte search for the markers would also match image data.
    private static func jpegHasIdentityAPP(_ data: Data) -> Bool {
        ImageMetadataStripper.scrubJPEGIfNeeded(data).count != data.count
    }

    static func hasTrailerFileID(_ graph: PDFDocumentGraph) -> Bool {
        graph.trailer["ID"] != nil
    }

    /// `/PieceInfo` on any object: the catalog, a page, a form XObject.
    static func hasPieceInfo(_ graph: PDFDocumentGraph) -> Bool {
        for (_, entry) in graph.objects {
            if let d = dict(of: entry.value), d["PieceInfo"] != nil { return true }
        }
        return false
    }
}
