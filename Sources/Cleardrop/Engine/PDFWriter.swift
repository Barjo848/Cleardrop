import Foundation

/// Serialize a `PDFDocumentGraph` to a fresh classic-xref PDF.
/// Stable object numbers; free slots for missing numbers; streams copy-through.
enum PDFWriter {
    static func write(_ graph: PDFDocumentGraph) throws -> Data {
        // Keep the input's version: 1.0–1.7 or 2.0. A classic table is valid in all of them.
        let major = graph.versionMajor >= 2 ? 2 : 1
        let minor = major == 2 ? 0 : min(max(graph.versionMinor, 0), 7)

        var out = Data()
        out.append(contentsOf: "%PDF-\(major).\(minor)\n".utf8)
        // Binary comment (4 bytes high-bit set) — recommended by spec
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        let maxObj = max(graph.size - 1, graph.objects.keys.max() ?? 0)
        if maxObj + 1 > PDFSanitizer.effectiveMaxObjectCount {
            throw PDFSanitizerError.unsupportedStructure("too many objects")
        }

        // offsets[objNum] = file offset of "n g obj"
        var offsets: [Int: Int] = [:]

        for objNum in 1...max(maxObj, 1) {
            guard let entry = graph.objects[objNum] else { continue }
            offsets[objNum] = out.count
            out.append(contentsOf: "\(objNum) \(entry.gen) obj\n".utf8)
            try appendValue(entry.value, to: &out)
            // ensure newline before endobj
            if let last = out.last, last != 10 && last != 13 {
                out.append(10)
            }
            out.append(contentsOf: "endobj\n".utf8)
        }

        let xrefPos = out.count
        out.append(contentsOf: "xref\n".utf8)
        let size = maxObj + 1
        out.append(contentsOf: "0 \(size)\n".utf8)
        // obj 0 free head
        out.append(contentsOf: "0000000000 65535 f \n".utf8)
        for objNum in 1..<size {
            if let off = offsets[objNum], let entry = graph.objects[objNum] {
                out.append(contentsOf: String(format: "%010d %05d n \n", off, entry.gen).utf8)
            } else {
                // free entry; gen 0 is fine for unused slots
                out.append(contentsOf: "0000000000 00000 f \n".utf8)
            }
        }

        out.append(contentsOf: "trailer\n".utf8)
        var trailer = graph.trailer
        trailer["Size"] = .int(size)
        // Drop Prev — full rewrite, not incremental
        trailer.removeValue(forKey: "Prev")
        trailer.removeValue(forKey: "XRefStm")
        // Never write Encrypt (fail-closed path should have rejected earlier)
        trailer.removeValue(forKey: "Encrypt")
        try appendValue(.dict(trailer), to: &out)
        out.append(contentsOf: "\nstartxref\n\(xrefPos)\n%%EOF\n".utf8)
        return out
    }

    // MARK: - Serialization

    private static func appendValue(_ value: PDFValue, to out: inout Data) throws {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let b):
            out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let n):
            out.append(contentsOf: "\(n)".utf8)
        case .real(let d):
            out.append(contentsOf: formatReal(d).utf8)
        case .name(let n):
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: encodeName(n).utf8)
        case .string(let data):
            out.append(UInt8(ascii: "("))
            out.append(escapeLiteral(data))
            out.append(UInt8(ascii: ")"))
        case .hexString(let data):
            out.append(UInt8(ascii: "<"))
            for b in data {
                out.append(contentsOf: String(format: "%02X", b).utf8)
            }
            out.append(UInt8(ascii: ">"))
        case .ref(let r):
            out.append(contentsOf: "\(r.obj) \(r.gen) R".utf8)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: " ")) }
                try appendValue(item, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let d):
            try appendDict(d, to: &out)
        case .stream(let d, let data):
            var dict = d
            dict["Length"] = .int(data.count)
            try appendDict(dict, to: &out)
            out.append(contentsOf: "\nstream\n".utf8)
            out.append(data)
            out.append(contentsOf: "\nendstream".utf8)
        }
    }

    private static func appendDict(_ d: [String: PDFValue], to out: inout Data) throws {
        out.append(contentsOf: "<<".utf8)
        // Stable key order for determinism in tests
        for key in d.keys.sorted() {
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: encodeName(key).utf8)
            out.append(UInt8(ascii: " "))
            try appendValue(d[key]!, to: &out)
        }
        out.append(contentsOf: ">>".utf8)
    }

    /// A real as plain decimal digits. PDF has no exponent syntax, so the shortest text that
    /// reads back as the same `Double` is expanded when it uses one.
    static func formatReal(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d.rounded() == d, abs(d) < 1e15 {
            return "\(Int(d))"
        }
        let text = "\(d)"
        guard let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return text
        }
        var mantissa = String(text[..<eIndex])
        let exponent = Int(text[text.index(after: eIndex)...]) ?? 0
        let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts.first ?? "0")
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let digits = whole + fraction
        // Position of the decimal point within `digits` after applying the exponent.
        let point = whole.count + exponent
        var result: String
        if point <= 0 {
            result = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            result = digits + String(repeating: "0", count: point - digits.count)
        } else {
            let split = digits.index(digits.startIndex, offsetBy: point)
            result = String(digits[..<split]) + "." + String(digits[split...])
        }
        if result.contains(".") {
            while result.hasSuffix("0") { result.removeLast() }
            if result.hasSuffix(".") { result.removeLast() }
        }
        return (negative ? "-" : "") + result
    }

    private static func encodeName(_ name: String) -> String {
        var s = ""
        for b in PDFName.bytes(of: name) {
            let c = Character(UnicodeScalar(b))
            if (b >= 33 && b <= 126)
                && c != "#" && c != "/" && c != "(" && c != ")"
                && c != "<" && c != ">" && c != "[" && c != "]"
                && c != "{" && c != "}" && c != "%"
            {
                s.append(c)
            } else {
                s.append(String(format: "#%02X", b))
            }
        }
        return s
    }

    private static func escapeLiteral(_ data: Data) -> Data {
        var out = Data()
        for b in data {
            switch b {
            case UInt8(ascii: "\\"), UInt8(ascii: "("), UInt8(ascii: ")"):
                out.append(UInt8(ascii: "\\"))
                out.append(b)
            case 10:
                out.append(contentsOf: "\\n".utf8)
            case 13:
                out.append(contentsOf: "\\r".utf8)
            case 9:
                out.append(contentsOf: "\\t".utf8)
            default:
                out.append(b)
            }
        }
        return out
    }
}
