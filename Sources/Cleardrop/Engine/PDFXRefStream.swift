import Foundation

/// One cross-reference section stored as a stream (PDF 1.5 and later).
enum PDFXRefStream {
    /// Keys that describe the stream itself rather than the document.
    private static let streamOnlyKeys: Set<String> = [
        "Type", "W", "Index", "Filter", "DecodeParms", "Length", "DL",
    ]

    static func parse(
        dict: [String: PDFValue],
        data: Data,
        budget: InflateBudget
    ) throws -> (entries: [Int: PDFXRefEntry], trailer: [String: PDFValue]) {
        guard case .some(.name(let type)) = dict["Type"], type == "XRef" else {
            throw PDFSanitizerError.corrupt("startxref does not point at a cross-reference section")
        }
        let maxObjects = PDFSanitizer.effectiveMaxObjectCount

        guard case .some(.int(let size)) = dict["Size"], size >= 0 else {
            throw PDFSanitizerError.corrupt("xref stream /Size")
        }
        guard size <= maxObjects else {
            throw PDFSanitizerError.unsupportedStructure("too many objects")
        }

        guard case .some(.array(let widthValues)) = dict["W"], widthValues.count == 3 else {
            throw PDFSanitizerError.corrupt("xref stream /W")
        }
        let widths = try widthValues.map { value -> Int in
            guard case .int(let w) = value, w >= 0, w <= 8 else {
                throw PDFSanitizerError.corrupt("xref stream /W")
            }
            return w
        }
        let rowSize = widths.reduce(0, +)
        guard rowSize > 0, widths[1] > 0 else {
            throw PDFSanitizerError.corrupt("xref stream /W")
        }

        // Subsections: pairs of (first object number, count). Default is one covering /Size.
        var subsections: [(first: Int, count: Int)] = []
        if let indexValue = dict["Index"] {
            guard case .array(let items) = indexValue, items.count % 2 == 0 else {
                throw PDFSanitizerError.corrupt("xref stream /Index")
            }
            var i = 0
            while i < items.count {
                guard case .int(let first) = items[i], case .int(let count) = items[i + 1],
                      first >= 0, count >= 0, first <= maxObjects, count <= maxObjects
                else {
                    throw PDFSanitizerError.corrupt("xref stream /Index")
                }
                subsections.append((first, count))
                i += 2
            }
        } else {
            subsections = [(0, size)]
        }
        let rowCount = subsections.reduce(0) { $0 + $1.count }
        guard rowCount <= maxObjects else {
            throw PDFSanitizerError.unsupportedStructure("too many objects")
        }

        let decoded = [UInt8](try StructuralStream.decode(dict: dict, data: data, budget: budget))
        guard decoded.count >= rowCount * rowSize else {
            throw PDFSanitizerError.corrupt("truncated xref stream")
        }

        func field(_ start: Int, _ width: Int) throws -> Int {
            var value: UInt64 = 0
            for k in 0..<width {
                value = value << 8 | UInt64(decoded[start + k])
            }
            guard value <= UInt64(Int.max) else {
                throw PDFSanitizerError.corrupt("xref stream field out of range")
            }
            return Int(value)
        }

        var entries: [Int: PDFXRefEntry] = [:]
        var position = 0
        for subsection in subsections {
            for n in 0..<subsection.count {
                // A missing type field means type 1.
                let type = widths[0] == 0 ? 1 : try field(position, widths[0])
                let second = try field(position + widths[0], widths[1])
                let third = widths[2] == 0 ? 0 : try field(position + widths[0] + widths[1], widths[2])
                position += rowSize

                let number = subsection.first + n
                switch type {
                case 0:
                    entries[number] = PDFXRefEntry(gen: third, kind: .free)
                case 1:
                    entries[number] = PDFXRefEntry(gen: third, kind: .inUse(offset: second))
                case 2:
                    entries[number] = PDFXRefEntry(gen: 0, kind: .compressed(stream: second, index: third))
                default:
                    // Reserved types refer to the null object.
                    entries[number] = PDFXRefEntry(gen: 0, kind: .free)
                }
            }
        }

        let trailer = dict.filter { !streamOnlyKeys.contains($0.key) }
        return (entries, trailer)
    }
}
