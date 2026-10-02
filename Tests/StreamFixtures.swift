import Foundation
import zlib

/// Generated PDFs that use cross-reference streams and object streams, laid out the way
/// common producers lay them out. They are stand-ins built from the specification, not
/// output of those producers; the interop tests cover real tools.
extension FixtureGenerator {
    // MARK: - Building blocks

    /// zlib-compress, whether or not the result is smaller.
    static func deflate(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let status = data.withUnsafeBytes { raw -> Int32 in
            compress2(&out, &length, raw.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), 6)
        }
        precondition(status == Z_OK, "deflate failed")
        return Data(out.prefix(Int(length)))
    }

    static func flateStreamObject(dict: String = "", payload: Data) -> Data {
        streamObject(dict: "/Filter /FlateDecode \(dict)", payload: deflate(payload))
    }

    static func bigEndian(_ value: Int, width: Int) -> [UInt8] {
        guard width > 0 else { return [] }
        return (0..<width).map { k in
            let shift = (width - 1 - k) * 8
            return shift >= 64 ? 0 : UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    /// PNG "Up" filter on every row, as `/Predictor 12` expects.
    static func pngUpFilter(rows: [[UInt8]]) -> Data {
        var out = Data()
        var previous = [UInt8](repeating: 0, count: rows.first?.count ?? 0)
        for row in rows {
            out.append(2)
            out.append(contentsOf: zip(row, previous).map { $0 &- $1 })
            previous = row
        }
        return out
    }

    struct StreamLayout {
        var version = "1.5"
        /// Object numbers stored inside object streams. Their bodies must not be streams,
        /// unless a test is deliberately building an invalid file.
        var compressed: Set<Int> = []
        /// How many object streams the compressed objects are spread across.
        var objectStreamCount = 1
        var widths = [1, 2, 1]
        var predictor = false
        var writeIndex = false
        var trailerExtra = ""

        // Deliberate damage, for tests that expect a refusal.
        var dropXRefRows = 0
        var memberIndexShift = 0
        var containerEntryCompressed = false
        var objectStreamPadding = 0
        var prevPointsAtItself = false
    }

    private enum Slot {
        case free
        case plain(offset: Int)
        case member(container: Int, index: Int)
    }

    private static func xrefStreamObject(
        number: Int,
        slots: [(number: Int, slot: Slot)],
        size: Int,
        layout: StreamLayout,
        offset: Int,
        prev: Int?,
        rootAndExtra: String
    ) -> Data {
        var rows: [[UInt8]] = []
        for (_, slot) in slots {
            let fields: (Int, Int, Int)
            switch slot {
            case .free: fields = (0, 0, 65535)
            case .plain(let offset): fields = (1, offset, 0)
            case .member(let container, let index): fields = (2, container, index + layout.memberIndexShift)
            }
            rows.append(
                bigEndian(fields.0, width: layout.widths[0])
                    + bigEndian(fields.1, width: layout.widths[1])
                    + bigEndian(fields.2, width: layout.widths[2])
            )
        }
        if layout.dropXRefRows > 0 {
            rows.removeLast(min(layout.dropXRefRows, rows.count))
        }
        let rowBytes = layout.widths.reduce(0, +)
        let raw = layout.predictor ? pngUpFilter(rows: rows) : Data(rows.flatMap { $0 })
        let payload = deflate(raw)

        var dict = "/Type /XRef /Size \(size) /W [\(layout.widths.map(String.init).joined(separator: " "))] \(rootAndExtra)"
        // Consecutive runs of object numbers become /Index subsections.
        var runs: [(first: Int, count: Int)] = []
        for (number, _) in slots {
            if let last = runs.last, last.first + last.count == number {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((number, 1))
            }
        }
        let isWholeRange = runs.count == 1 && runs[0].first == 0 && runs[0].count == size
        if layout.writeIndex || !isWholeRange {
            dict += " /Index [\(runs.map { "\($0.first) \($0.count)" }.joined(separator: " "))]"
        }
        if layout.predictor {
            dict += " /DecodeParms << /Columns \(rowBytes) /Predictor 12 >>"
        }
        if let prev {
            dict += " /Prev \(prev)"
        }
        if layout.prevPointsAtItself {
            dict += " /Prev \(offset)"
        }
        var out = Data("\(number) 0 obj\n".utf8)
        out.append(streamObject(dict: "/Filter /FlateDecode \(dict)", payload: payload))
        out.append(Data("\nendobj\n".utf8))
        return out
    }

    private static func objectStreamBody(members: [(number: Int, body: Data)], padding: Int) -> (dict: String, payload: Data) {
        var header = ""
        var bodies = Data()
        for member in members {
            header += "\(member.number) \(bodies.count) "
            bodies.append(member.body)
            bodies.append(10)
        }
        var decoded = Data(header.utf8)
        let first = decoded.count
        decoded.append(bodies)
        if padding > 0 {
            decoded.append(Data(repeating: 0x20, count: padding))
        }
        return ("/Type /ObjStm /N \(members.count) /First \(first)", decoded)
    }

    // MARK: - Whole files

    /// A file whose only cross-reference section is a stream.
    static func xrefStreamPDF(
        objects: [(number: Int, body: Data)],
        layout: StreamLayout
    ) -> Data {
        var out = Data("%PDF-\(layout.version)\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var slots: [Int: Slot] = [:]
        var nextNumber = (objects.map(\.number).max() ?? 0) + 1

        for object in objects where !layout.compressed.contains(object.number) {
            slots[object.number] = .plain(offset: out.count)
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }

        let packed = objects.filter { layout.compressed.contains($0.number) }
        if !packed.isEmpty {
            let groups = max(1, min(layout.objectStreamCount, packed.count))
            for g in 0..<groups {
                let members = packed.enumerated().filter { $0.offset % groups == g }.map(\.element)
                let container = nextNumber
                nextNumber += 1
                let stream = objectStreamBody(members: members, padding: layout.objectStreamPadding)
                slots[container] = layout.containerEntryCompressed
                    ? .member(container: container, index: 0)
                    : .plain(offset: out.count)
                out.append(Data("\(container) 0 obj\n".utf8))
                out.append(flateStreamObject(dict: stream.dict, payload: stream.payload))
                out.append(Data("\nendobj\n".utf8))
                for (index, member) in members.enumerated() {
                    slots[member.number] = .member(container: container, index: index)
                }
            }
        }

        let xrefNumber = nextNumber
        let xrefOffset = out.count
        slots[xrefNumber] = .plain(offset: xrefOffset)
        let size = xrefNumber + 1
        let ordered: [(number: Int, slot: Slot)] = (0..<size).map { ($0, slots[$0] ?? .free) }
        out.append(xrefStreamObject(
            number: xrefNumber, slots: ordered, size: size, layout: layout,
            offset: xrefOffset, prev: nil, rootAndExtra: "/Root 1 0 R \(layout.trailerExtra)"
        ))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    /// Append an incremental update whose cross-reference section is a stream.
    static func appendingStreamUpdate(
        to base: Data,
        objects: [(number: Int, body: Data)],
        xrefNumber: Int,
        layout: StreamLayout
    ) -> Data {
        var out = base
        var slots: [(number: Int, slot: Slot)] = []
        for object in objects.sorted(by: { $0.number < $1.number }) {
            slots.append((object.number, .plain(offset: out.count)))
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        slots.append((xrefNumber, .plain(offset: xrefOffset)))
        slots.sort { $0.number < $1.number }
        out.append(xrefStreamObject(
            number: xrefNumber, slots: slots, size: xrefNumber + 1, layout: layout,
            offset: xrefOffset, prev: lastStartXRef(of: base),
            rootAndExtra: "/Root 1 0 R \(layout.trailerExtra)"
        ))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    /// A hybrid file: a classic table that old readers can use, in which the objects kept in
    /// an object stream appear free, plus a cross-reference stream (`/XRefStm`) that locates them.
    static func hybridPDF(
        objects: [(number: Int, body: Data)],
        compressed: Set<Int>,
        trailerExtra: String
    ) -> Data {
        var out = Data("%PDF-1.5\n".utf8)
        var plainOffsets: [Int: Int] = [:]
        for object in objects where !compressed.contains(object.number) {
            plainOffsets[object.number] = out.count
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }
        let members = objects.filter { compressed.contains($0.number) }
        let container = (objects.map(\.number).max() ?? 0) + 1
        let xrefStreamNumber = container + 1
        let stream = objectStreamBody(members: members, padding: 0)
        plainOffsets[container] = out.count
        out.append(Data("\(container) 0 obj\n".utf8))
        out.append(flateStreamObject(dict: stream.dict, payload: stream.payload))
        out.append(Data("\nendobj\n".utf8))

        let streamOffset = out.count
        plainOffsets[xrefStreamNumber] = streamOffset
        let size = xrefStreamNumber + 1
        let hidden: [(number: Int, slot: Slot)] = members.enumerated()
            .map { ($0.element.number, Slot.member(container: container, index: $0.offset)) }
            .sorted { $0.number < $1.number }
        out.append(xrefStreamObject(
            number: xrefStreamNumber, slots: hidden, size: size, layout: StreamLayout(widths: [1, 2, 1]),
            offset: streamOffset, prev: nil, rootAndExtra: "/Root 1 0 R"
        ))

        let tableOffset = out.count
        out.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for number in 1..<size {
            if let offset = plainOffsets[number] {
                out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else {
                out.append(Data("0000000000 00000 f \n".utf8))
            }
        }
        out.append(Data("trailer\n<< /Size \(size) /Root 1 0 R \(trailerExtra) /XRefStm \(streamOffset) >>\n".utf8))
        out.append(Data("startxref\n\(tableOffset)\n%%EOF\n".utf8))
        return out
    }

    // MARK: - Document content shared by the profiles

    static let knownIDEntry = "/ID [<\(CleardropTests.knownID_A)> <\(CleardropTests.knownID_A)>]"

    /// Catalog, page tree, `pageCount` pages with Flate-compressed content, one font.
    /// Object numbers: 1 catalog, 2 pages, 3 font, then (page, content) pairs from 4.
    static func compressedPagesObjects(
        texts: [String],
        catalogExtra: String = "",
        indirectLengths: Bool = false
    ) -> (objects: [(number: Int, body: Data)], next: Int) {
        var objects: [(number: Int, body: Data)] = []
        var kids: [String] = []
        var number = 4
        var lengthObjects: [(number: Int, body: Data)] = []
        let lengthBase = 4 + texts.count * 2
        for (index, text) in texts.enumerated() {
            let page = number
            let content = number + 1
            number += 2
            kids.append("\(page) 0 R")
            objects.append((page, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R /Resources << /Font << /F1 3 0 R >> >> >>".utf8)))
            let payload = deflate(Data("BT /F1 14 Tf 72 700 Td (\(text)) Tj ET".utf8))
            if indirectLengths {
                let lengthNumber = lengthBase + index
                var body = Data("<< /Filter /FlateDecode /Length \(lengthNumber) 0 R >>\nstream\n".utf8)
                body.append(payload)
                body.append(Data("\nendstream".utf8))
                objects.append((content, body))
                lengthObjects.append((lengthNumber, Data("\(payload.count)".utf8)))
            } else {
                objects.append((content, streamObject(dict: "/Filter /FlateDecode", payload: payload)))
            }
        }
        objects.append(contentsOf: lengthObjects)
        objects.insert((1, Data("<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>".utf8)), at: 0)
        objects.insert((2, Data("<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(texts.count) >>".utf8)), at: 1)
        objects.insert((3, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)), at: 2)
        let next = (objects.map(\.number).max() ?? 0) + 1
        return (objects, next)
    }

    // MARK: - Profiles

    struct CorpusFile {
        var name: String
        var data: Data
        var pages: Int
        var texts: [String]
    }

    /// pdfTeX layout: PDF 1.5, everything except streams packed into one object stream,
    /// a plain cross-reference stream with no predictor, Info with the pdfTeX keys.
    static let pdfTeXLike: CorpusFile = {
        var (objects, next) = compressedPagesObjects(texts: ["TeX page one", "TeX page two"])
        let info = next
        objects.append((info, Data("<< /Producer (pdfTeX-1.40.27) /Creator (TeX) /Author (\(CleardropTests.plantedAuthor)) /CreationDate (D:20200101000000Z) /PTEX.Fullbanner (\(CleardropTests.plantedProducer)) /Trapped /False >>".utf8)))
        let streams = Set(objects.filter { $0.body.range(of: Data("stream\n".utf8)) != nil }.map(\.number))
        var layout = StreamLayout()
        layout.compressed = Set(objects.map(\.number)).subtracting(streams)
        layout.trailerExtra = "/Info \(info) 0 R \(knownIDEntry)"
        return CorpusFile(name: "pdfTeX-like", data: xrefStreamPDF(objects: objects, layout: layout), pages: 2, texts: ["TeX page one", "TeX page two"])
    }()

    /// Acrobat layout: PDF 1.6, predictor 12 with wide fields and /Index, catalog XMP,
    /// a leftover linearization dictionary, then an incremental save as a second stream section.
    static let acrobatLike: CorpusFile = {
        var (objects, next) = compressedPagesObjects(
            texts: ["Acrobat page one", "Acrobat page two"],
            catalogExtra: "/Metadata 20 0 R"
        )
        let xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/'><xmpMM:DocumentID>\(CleardropTests.plantedXmpDocID)</xmpMM:DocumentID></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        objects.append((20, streamObject(dict: "/Type /Metadata /Subtype /XML", payload: Data(xmp.utf8))))
        objects.append((21, Data("<< /Linearized 1 /L 4096 /H [600 200] /O 4 /E 2000 /N 2 /T 3000 >>".utf8)))
        objects.append((22, Data("<< /Producer (\(CleardropTests.plantedProducer)) /Title (First save) >>".utf8)))
        _ = next
        var layout = StreamLayout()
        layout.version = "1.6"
        layout.compressed = [1, 2, 3, 4, 6, 22]
        layout.widths = [1, 4, 2]
        layout.predictor = true
        layout.writeIndex = true
        layout.trailerExtra = "/Info 22 0 R \(knownIDEntry)"
        let base = xrefStreamPDF(objects: objects, layout: layout)
        // xrefStreamPDF used 23 for the object stream and 24 for the cross-reference stream.
        var update = StreamLayout()
        update.widths = [1, 4, 2]
        update.predictor = true
        update.trailerExtra = "/Info 22 0 R \(knownIDEntry)"
        let saved = appendingStreamUpdate(
            to: base,
            objects: [(22, Data("<< /Producer (\(CleardropTests.plantedProducer)) /Author (\(CleardropTests.plantedAuthor)) /ModDate (D:20210101000000Z) >>".utf8))],
            xrefNumber: 25,
            layout: update
        )
        return CorpusFile(name: "Acrobat-like", data: saved, pages: 2, texts: ["Acrobat page one", "Acrobat page two"])
    }()

    /// Layout of current generators that optimise for size: several object streams,
    /// predictor 12, three-byte offsets, stream lengths stored as objects inside an object
    /// stream, and a plain Info object.
    static func modernGeneratorLike(version: String = "1.7") -> CorpusFile {
        let texts = ["Modern page one", "Modern page two", "Modern page three"]
        var (objects, next) = compressedPagesObjects(texts: texts, indirectLengths: true)
        let info = next
        objects.append((info, Data("<< /Producer (\(CleardropTests.plantedProducer)) /Creator (\(CleardropTests.plantedCreator)) /Author (\(CleardropTests.plantedAuthor)) >>".utf8)))
        let streams = Set(objects.filter { $0.body.range(of: Data("stream\n".utf8)) != nil }.map(\.number))
        var layout = StreamLayout()
        layout.version = version
        layout.compressed = Set(objects.map(\.number)).subtracting(streams).subtracting([info])
        layout.objectStreamCount = 2
        layout.widths = [1, 3, 1]
        layout.predictor = true
        layout.trailerExtra = "/Info \(info) 0 R \(knownIDEntry)"
        return CorpusFile(name: "modern-generator-like (PDF \(version))", data: xrefStreamPDF(objects: objects, layout: layout), pages: 3, texts: texts)
    }

    /// Hybrid layout, as written by office suites for compatibility with old readers.
    static let hybridLike: CorpusFile = {
        var (objects, next) = compressedPagesObjects(texts: ["Hybrid page"])
        let info = next
        objects.append((info, Data("<< /Author (\(CleardropTests.plantedAuthor)) /Producer (\(CleardropTests.plantedProducer)) >>".utf8)))
        // The catalog stays visible to old readers; the page tree, font, page and Info are hidden.
        let data = hybridPDF(objects: objects, compressed: [2, 3, 4, info], trailerExtra: "/Info \(info) 0 R \(knownIDEntry)")
        return CorpusFile(name: "hybrid", data: data, pages: 1, texts: ["Hybrid page"])
    }()

    /// Every generated file that Cleardrop claims to clean.
    static var corpus: [CorpusFile] {
        [pdfTeXLike, acrobatLike, modernGeneratorLike(), modernGeneratorLike(version: "2.0"), hybridLike]
    }

    /// The pdfTeX-like file with one change applied, for refusal tests.
    static func pdfTeXLikeVariant(
        extraObjects: [(number: Int, body: Data)] = [],
        compressExtra: Bool = true,
        trailerExtra: String = "",
        _ change: (inout StreamLayout) -> Void = { _ in }
    ) -> Data {
        var (objects, next) = compressedPagesObjects(texts: ["TeX page one", "TeX page two"])
        let info = next
        objects.append((info, Data("<< /Producer (pdfTeX-1.40.27) /Author (\(CleardropTests.plantedAuthor)) >>".utf8)))
        let streams = Set(objects.filter { $0.body.range(of: Data("stream\n".utf8)) != nil }.map(\.number))
        var layout = StreamLayout()
        layout.compressed = Set(objects.map(\.number)).subtracting(streams)
        objects.append(contentsOf: extraObjects)
        if compressExtra {
            layout.compressed.formUnion(extraObjects.map(\.number))
        }
        layout.trailerExtra = "/Info \(info) 0 R \(knownIDEntry) \(trailerExtra)"
        change(&layout)
        return xrefStreamPDF(objects: objects, layout: layout)
    }
}
