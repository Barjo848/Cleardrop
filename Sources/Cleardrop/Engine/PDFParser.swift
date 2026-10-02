import Foundation

/// PDF parser.
/// - Reads classic `xref` tables, cross-reference streams, and hybrid files that use both.
/// - Follows the `/Prev` chain, so incrementally saved files are read whole.
/// - Expands object streams; the graph it returns holds every object as a plain object and
///   does not include the object-stream or cross-reference-stream containers themselves.
/// - Fails closed on `/Encrypt`, before reading any object.
/// - Anything it cannot read exactly throws; it never guesses.
enum PDFParser {
    /// Arrays and dictionaries nested deeper than this are rejected rather than recursed into.
    static let maxNestingDepth = 256
    /// Upper bound on cross-reference sections in one file.
    static let maxXRefSections = 4096

    static func parse(_ data: Data) throws -> PDFDocumentGraph {
        guard data.count >= 8 else { throw PDFSanitizerError.notPDF }
        let (major, minor) = try parseHeaderVersion(data)
        let xrefOffset = try findStartXrefOffset(data)
        let budget = InflateBudget(PDFSanitizer.effectiveMaxInflatedBytes)
        let (entries, rawTrailer) = try loadXRefChain(data, startingAt: xrefOffset, budget: budget)
        if rawTrailer["Encrypt"] != nil {
            // Fail before interpreting encrypted object bodies.
            throw PDFSanitizerError.encrypted
        }
        var trailer = rawTrailer
        trailer.removeValue(forKey: "XRefStm")

        let sizeHint = intFrom(trailer["Size"]) ?? (entries.keys.max().map { $0 + 1 } ?? 1)
        let maxObjs = PDFSanitizer.effectiveMaxObjectCount
        if sizeHint > maxObjs || entries.count > maxObjs {
            throw PDFSanitizerError.unsupportedStructure("too many objects")
        }

        let loader = ObjectLoader(data: data, entries: entries, budget: budget)
        var objects: [Int: (gen: Int, value: PDFValue)] = [:]
        for (objNum, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let value = try loader.value(of: objNum) else { continue }
            // The containers are file structure, not document content: their members are
            // loaded as objects in their own right, and the writer builds a new table.
            if case .stream(let dict, _) = value, case .some(.name(let type)) = dict["Type"],
               type == "ObjStm" || type == "XRef"
            {
                continue
            }
            let gen: Int
            if case .compressed = entry.kind { gen = 0 } else { gen = entry.gen }
            objects[objNum] = (gen, value)
        }

        let maxObj = objects.keys.max() ?? 0
        let size = max(sizeHint, maxObj + 1)

        return PDFDocumentGraph(
            versionMajor: major,
            versionMinor: minor,
            objects: objects,
            trailer: trailer,
            size: size
        )
    }

    // MARK: - Header

    private static func parseHeaderVersion(_ data: Data) throws -> (Int, Int) {
        // %PDF-1.N
        guard data.starts(with: Data("%PDF-".utf8)) else {
            throw PDFSanitizerError.notPDF
        }
        var i = 5
        var major = 0
        while i < data.count, let c = ascii(data[i]), c >= 48 && c <= 57 {
            major = major * 10 + Int(c - 48)
            i += 1
        }
        guard i < data.count, data[i] == UInt8(ascii: ".") else {
            return (max(major, 1), 4)
        }
        i += 1
        var minor = 0
        while i < data.count, let c = ascii(data[i]), c >= 48 && c <= 57 {
            minor = minor * 10 + Int(c - 48)
            i += 1
        }
        return (major == 0 ? 1 : major, minor)
    }

    // MARK: - startxref

    private static func findStartXrefOffset(_ data: Data) throws -> Int {
        // Search last ~64KB for startxref
        let window = min(data.count, 65536)
        let start = data.count - window
        let slice = data.subdata(in: start..<data.count)
        guard let range = slice.range(of: Data("startxref".utf8), options: .backwards) else {
            throw PDFSanitizerError.corrupt("missing startxref")
        }
        var i = start + range.upperBound
        skipWhitespaceAndComments(data, &i)
        let (num, next) = try readNumberToken(data, at: i)
        _ = next
        guard let offset = num.intValue, offset >= 0, offset < data.count else {
            throw PDFSanitizerError.corrupt("bad startxref offset")
        }
        return offset
    }

    // MARK: - xref + trailer

    /// Walk the cross-reference sections from the newest back through `/Prev`.
    /// The newest section wins for each object number; older sections fill the gaps.
    /// The returned trailer is the newest one.
    private static func loadXRefChain(
        _ data: Data,
        startingAt start: Int,
        budget: InflateBudget
    ) throws -> (entries: [Int: PDFXRefEntry], trailer: [String: PDFValue]) {
        var entries: [Int: PDFXRefEntry] = [:]
        var newestTrailer: [String: PDFValue]?
        var visited = Set<Int>()
        var offset = start

        while true {
            guard visited.insert(offset).inserted else {
                throw PDFSanitizerError.corrupt("cyclic /Prev chain")
            }
            guard visited.count <= maxXRefSections else {
                throw PDFSanitizerError.unsupportedStructure("too many xref sections")
            }
            var section = try parseXRefAndTrailer(data, at: offset)
            if section.isXRefStream {
                let stream = try parseXRefStreamSection(data, at: offset, budget: budget)
                section = (stream.entries, stream.trailer, true)
            }
            // Entries this section marks free, which its own /XRefStm may override.
            var freeInThisSection = Set<Int>()
            for (objNum, entry) in section.entries where entries[objNum] == nil {
                entries[objNum] = entry
                if case .free = entry.kind { freeInThisSection.insert(objNum) }
            }
            // Hybrid file: a classic table for old readers, plus a stream that lists the
            // objects kept in object streams. The table shows those objects as free.
            if !section.isXRefStream, let hybrid = section.trailer["XRefStm"] {
                guard case .int(let hybridOffset) = hybrid, hybridOffset >= 0, hybridOffset < data.count,
                      visited.insert(hybridOffset).inserted
                else {
                    throw PDFSanitizerError.corrupt("bad /XRefStm offset")
                }
                let stream = try parseXRefStreamSection(data, at: hybridOffset, budget: budget)
                for (objNum, entry) in stream.entries
                    where entries[objNum] == nil || freeInThisSection.contains(objNum)
                {
                    entries[objNum] = entry
                }
            }
            if newestTrailer == nil {
                newestTrailer = section.trailer
            }
            guard let prev = section.trailer["Prev"] else { break }
            guard case .int(let prevOffset) = prev, prevOffset >= 0, prevOffset < data.count else {
                throw PDFSanitizerError.corrupt("bad /Prev offset")
            }
            offset = prevOffset
        }
        return (entries, newestTrailer ?? [:])
    }

    /// A cross-reference section stored as a stream object at `offset`.
    private static func parseXRefStreamSection(
        _ data: Data,
        at offset: Int,
        budget: InflateBudget
    ) throws -> (entries: [Int: PDFXRefEntry], trailer: [String: PDFValue]) {
        guard let header = peekObjectHeader(data, at: offset) else {
            throw PDFSanitizerError.corrupt("expected a cross-reference stream")
        }
        // Its /Length must be a direct number: no table exists yet to look anything up in.
        let value = try parseIndirectObject(
            data, at: offset, expectObj: header.0, expectGen: header.1,
            lengthResolver: { _ in nil }
        )
        guard case .stream(let dict, let payload) = value else {
            throw PDFSanitizerError.corrupt("cross-reference section is not a stream")
        }
        return try PDFXRefStream.parse(dict: dict, data: payload, budget: budget)
    }

    private static func parseXRefAndTrailer(
        _ data: Data,
        at offset: Int
    ) throws -> (entries: [Int: PDFXRefEntry], trailer: [String: PDFValue], isXRefStream: Bool) {
        var i = offset
        skipWhitespaceAndComments(data, &i)
        // xref stream objects start with `n 0 obj`
        if let _ = peekObjectHeader(data, at: i) {
            return ([:], [:], true)
        }
        guard matchKeyword(data, &i, "xref") else {
            // Might still be xref stream without us detecting header
            if peekObjectHeader(data, at: i) != nil {
                return ([:], [:], true)
            }
            throw PDFSanitizerError.corrupt("expected xref")
        }
        skipWhitespaceAndComments(data, &i)

        var entries: [Int: PDFXRefEntry] = [:]
        // subsections until "trailer"
        while i < data.count {
            skipWhitespaceAndComments(data, &i)
            if matchKeyword(data, &i, "trailer") {
                break
            }
            // start count
            let (startTok, i1) = try readNumberToken(data, at: i)
            i = i1
            skipWhitespaceAndComments(data, &i)
            let (countTok, i2) = try readNumberToken(data, at: i)
            i = i2
            guard let start = startTok.intValue, let count = countTok.intValue, count >= 0 else {
                throw PDFSanitizerError.corrupt("bad xref subsection")
            }
            skipWhitespaceAndComments(data, &i)
            for n in 0..<count {
                // Each entry: 20 bytes typically "OOOOOOOOOO GGGGG n \n" but be flexible
                skipWhitespaceAndComments(data, &i)
                let (offTok, j1) = try readNumberToken(data, at: i)
                i = j1
                skipWhitespaceAndComments(data, &i)
                let (genTok, j2) = try readNumberToken(data, at: i)
                i = j2
                skipWhitespaceAndComments(data, &i)
                guard i < data.count else { throw PDFSanitizerError.corrupt("truncated xref entry") }
                let flag = data[i]
                i += 1
                guard let off = offTok.intValue, let gen = genTok.intValue else {
                    throw PDFSanitizerError.corrupt("bad xref entry numbers")
                }
                let objNum = start + n
                if flag == UInt8(ascii: "n") {
                    // Byte 0 is the file header, so no object can be there. Quartz (Safari and
                    // "Save as PDF") writes such an entry for object numbers it never used.
                    // The object does not exist; a reference to it is a reference to null.
                    entries[objNum] = off == 0
                        ? PDFXRefEntry(gen: gen, kind: .free)
                        : PDFXRefEntry(gen: gen, kind: .inUse(offset: off))
                } else if flag == UInt8(ascii: "f") {
                    entries[objNum] = PDFXRefEntry(gen: gen, kind: .free)
                } else {
                    throw PDFSanitizerError.corrupt("bad xref flag")
                }
                // consume rest of line optionally
                while i < data.count {
                    let c = data[i]
                    if c == 10 || c == 13 { break }
                    if c == UInt8(ascii: " ") || c == 9 { i += 1; continue }
                    break
                }
                if i < data.count && data[i] == 13 {
                    i += 1
                    if i < data.count && data[i] == 10 { i += 1 }
                } else if i < data.count && data[i] == 10 {
                    i += 1
                }
            }
            skipWhitespaceAndComments(data, &i)
        }

        skipWhitespaceAndComments(data, &i)
        let trailerVal = try parseValue(data, &i)
        guard case .dict(let trailer) = trailerVal else {
            throw PDFSanitizerError.corrupt("trailer is not a dict")
        }

        return (entries, trailer, false)
    }

    // MARK: - Object streams

    /// One object inside a decoded object stream. Streams cannot be stored there.
    static func parseObjectStreamMember(_ decoded: Data, at offset: Int) throws -> PDFValue {
        var i = offset
        return try parseValue(decoded, &i, allowStream: false)
    }

    /// Exactly `count` non-negative integers separated by whitespace.
    static func readIntegers(_ data: Data, count: Int) throws -> [Int] {
        let bytes = Data(data)
        var values: [Int] = []
        values.reserveCapacity(count)
        var i = 0
        for _ in 0..<count {
            skipWhitespaceAndComments(bytes, &i)
            let (token, next) = try readNumberToken(bytes, at: i)
            guard let value = token.intValue, !token.wasReal, value >= 0 else {
                throw PDFSanitizerError.corrupt("object stream header")
            }
            values.append(value)
            i = next
        }
        return values
    }

    // MARK: - Indirect object

    fileprivate static func parseIndirectObject(
        _ data: Data,
        at offset: Int,
        expectObj: Int,
        expectGen: Int,
        lengthResolver: @escaping (PDFRef) -> Int?
    ) throws -> PDFValue {
        var i = offset
        skipWhitespaceAndComments(data, &i)
        let (objTok, i1) = try readNumberToken(data, at: i)
        i = i1
        skipWhitespaceAndComments(data, &i)
        let (genTok, i2) = try readNumberToken(data, at: i)
        i = i2
        skipWhitespaceAndComments(data, &i)
        guard matchKeyword(data, &i, "obj") else {
            throw PDFSanitizerError.corrupt("expected obj")
        }
        guard objTok.intValue == expectObj, genTok.intValue == expectGen else {
            throw PDFSanitizerError.corrupt("object header mismatch \(expectObj)")
        }
        skipWhitespaceAndComments(data, &i)
        let value = try parseValue(data, &i, lengthResolver: lengthResolver)
        skipWhitespaceAndComments(data, &i)
        // optional endobj
        _ = matchKeyword(data, &i, "endobj")
        return value
    }

    // MARK: - Values

    private static func parseValue(
        _ data: Data,
        _ i: inout Int,
        lengthResolver: ((PDFRef) -> Int?)? = nil,
        depth: Int = 0,
        allowStream: Bool = true
    ) throws -> PDFValue {
        skipWhitespaceAndComments(data, &i)
        guard i < data.count else { throw PDFSanitizerError.corrupt("unexpected EOF in value") }
        let c = data[i]

        // Dict or hex string
        if c == UInt8(ascii: "<") {
            if i + 1 < data.count && data[i + 1] == UInt8(ascii: "<") {
                guard depth < maxNestingDepth else {
                    throw PDFSanitizerError.corrupt("nesting too deep")
                }
                return try parseDict(
                    data, &i, lengthResolver: lengthResolver, depth: depth + 1,
                    allowStream: allowStream
                )
            }
            return try parseHexString(data, &i)
        }
        // Array
        if c == UInt8(ascii: "[") {
            guard depth < maxNestingDepth else {
                throw PDFSanitizerError.corrupt("nesting too deep")
            }
            return try parseArray(
                data, &i, lengthResolver: lengthResolver, depth: depth + 1,
                allowStream: allowStream
            )
        }
        // Literal string
        if c == UInt8(ascii: "(") {
            return try parseLiteralString(data, &i)
        }
        // Name
        if c == UInt8(ascii: "/") {
            return .name(try parseName(data, &i))
        }
        // Ref or number: read number, maybe another number + R
        if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".")
            || (c >= 48 && c <= 57)
        {
            let (tok, i1) = try readNumberToken(data, at: i)
            i = i1
            // Lookahead for gen R
            var j = i
            skipWhitespaceAndComments(data, &j)
            if let (genTok, j1) = try? readNumberToken(data, at: j) {
                var k = j1
                skipWhitespaceAndComments(data, &k)
                if matchKeyword(data, &k, "R"), let obj = tok.intValue, let gen = genTok.intValue {
                    i = k
                    return .ref(PDFRef(obj: obj, gen: gen))
                }
            }
            if let iv = tok.intValue, !tok.wasReal {
                return .int(iv)
            }
            return .real(tok.doubleValue)
        }
        // keywords: true false null
        if matchKeyword(data, &i, "true") { return .bool(true) }
        if matchKeyword(data, &i, "false") { return .bool(false) }
        if matchKeyword(data, &i, "null") { return .null }

        throw PDFSanitizerError.corrupt("unexpected token at \(i)")
    }

    private static func parseDict(
        _ data: Data,
        _ i: inout Int,
        lengthResolver: ((PDFRef) -> Int?)?,
        depth: Int,
        allowStream: Bool
    ) throws -> PDFValue {
        guard i + 1 < data.count,
              data[i] == UInt8(ascii: "<"),
              data[i + 1] == UInt8(ascii: "<")
        else {
            throw PDFSanitizerError.corrupt("expected <<")
        }
        i += 2
        var dict: [String: PDFValue] = [:]
        while true {
            skipWhitespaceAndComments(data, &i)
            if i + 1 < data.count,
               data[i] == UInt8(ascii: ">"),
               data[i + 1] == UInt8(ascii: ">")
            {
                i += 2
                break
            }
            let key = try parseName(data, &i)
            let val = try parseValue(
                data, &i, lengthResolver: lengthResolver, depth: depth, allowStream: allowStream
            )
            dict[key] = val
        }
        // Stream?
        skipWhitespaceAndComments(data, &i)
        if matchKeyword(data, &i, "stream") {
            guard allowStream else {
                throw PDFSanitizerError.corrupt("stream inside an object stream")
            }
            // EOL after stream keyword
            if i < data.count && data[i] == 13 {
                i += 1
                if i < data.count && data[i] == 10 { i += 1 }
            } else if i < data.count && data[i] == 10 {
                i += 1
            }
            let length: Int?
            if let n = intFrom(dict["Length"]) {
                length = n
            } else if case .ref(let r) = dict["Length"], let resolver = lengthResolver {
                length = resolver(r)
            } else {
                length = nil
            }
            // The payload is exactly /Length bytes and `endstream` must follow. A length that
            // is missing or wrong is not repaired by searching for `endstream`: that word can
            // occur inside binary data, and a guess would silently change the stream.
            guard let length, length >= 0, length <= data.count - i else {
                throw PDFSanitizerError.corrupt("stream /Length missing or out of range")
            }
            let streamData = data.subdata(in: i..<(i + length))
            i += length
            while i < data.count, isWhitespace(data[i]) { i += 1 }
            guard matchKeyword(data, &i, "endstream") else {
                throw PDFSanitizerError.corrupt("stream /Length does not end at endstream")
            }
            // Hold the length as a number. The writer always writes it that way, so a
            // separate length object would otherwise be kept alive for nothing.
            dict["Length"] = .int(length)
            return .stream(dict: dict, data: streamData)
        }
        return .dict(dict)
    }

    private static func parseArray(
        _ data: Data,
        _ i: inout Int,
        lengthResolver: ((PDFRef) -> Int?)?,
        depth: Int,
        allowStream: Bool
    ) throws -> PDFValue {
        guard i < data.count, data[i] == UInt8(ascii: "[") else {
            throw PDFSanitizerError.corrupt("expected [")
        }
        i += 1
        var items: [PDFValue] = []
        while true {
            skipWhitespaceAndComments(data, &i)
            if i < data.count && data[i] == UInt8(ascii: "]") {
                i += 1
                break
            }
            items.append(try parseValue(
                data, &i, lengthResolver: lengthResolver, depth: depth, allowStream: allowStream
            ))
        }
        return .array(items)
    }

    private static func parseName(_ data: Data, _ i: inout Int) throws -> String {
        guard i < data.count, data[i] == UInt8(ascii: "/") else {
            throw PDFSanitizerError.corrupt("expected name")
        }
        i += 1
        var bytes = [UInt8]()
        while i < data.count {
            let c = data[i]
            if isDelimiter(c) || isWhitespace(c) { break }
            if c == UInt8(ascii: "#"), i + 2 < data.count {
                let h1 = data[i + 1]
                let h2 = data[i + 2]
                if let v1 = hexNibble(h1), let v2 = hexNibble(h2) {
                    bytes.append(v1 << 4 | v2)
                    i += 3
                    continue
                }
            }
            bytes.append(c)
            i += 1
        }
        return PDFName.string(fromBytes: bytes)
    }

    private static func parseLiteralString(_ data: Data, _ i: inout Int) throws -> PDFValue {
        guard i < data.count, data[i] == UInt8(ascii: "(") else {
            throw PDFSanitizerError.corrupt("expected (")
        }
        i += 1
        var out = Data()
        var depth = 1
        while i < data.count {
            let c = data[i]
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < data.count else { break }
                let e = data[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case UInt8(ascii: "("): out.append(UInt8(ascii: "("))
                case UInt8(ascii: ")"): out.append(UInt8(ascii: ")"))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "\n"): break
                case UInt8(ascii: "\r"):
                    if i < data.count && data[i] == 10 { i += 1 }
                default:
                    // octal up to 3 digits
                    if e >= 48 && e <= 55 {
                        var v = Int(e - 48)
                        var digits = 1
                        while digits < 3, i < data.count {
                            let d = data[i]
                            if d >= 48 && d <= 55 {
                                v = v * 8 + Int(d - 48)
                                i += 1
                                digits += 1
                            } else { break }
                        }
                        out.append(UInt8(v & 0xFF))
                    } else {
                        out.append(e)
                    }
                }
                continue
            }
            if c == UInt8(ascii: "(") {
                depth += 1
                out.append(c)
                i += 1
                continue
            }
            if c == UInt8(ascii: ")") {
                depth -= 1
                i += 1
                if depth == 0 { break }
                out.append(c)
                continue
            }
            out.append(c)
            i += 1
        }
        guard depth == 0 else {
            throw PDFSanitizerError.corrupt("unterminated string")
        }
        return .string(out)
    }

    private static func parseHexString(_ data: Data, _ i: inout Int) throws -> PDFValue {
        guard i < data.count, data[i] == UInt8(ascii: "<") else {
            throw PDFSanitizerError.corrupt("expected <")
        }
        i += 1
        var nibbles = [UInt8]()
        var terminated = false
        while i < data.count {
            let c = data[i]
            if c == UInt8(ascii: ">") {
                i += 1
                terminated = true
                break
            }
            if isWhitespace(c) {
                i += 1
                continue
            }
            guard let n = hexNibble(c) else {
                throw PDFSanitizerError.corrupt("bad hex string")
            }
            nibbles.append(n)
            i += 1
        }
        guard terminated else {
            throw PDFSanitizerError.corrupt("unterminated hex string")
        }
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        var out = Data()
        var idx = 0
        while idx < nibbles.count {
            out.append(nibbles[idx] << 4 | nibbles[idx + 1])
            idx += 2
        }
        return .hexString(out)
    }

    // MARK: - Token helpers

    private struct NumTok {
        var intValue: Int?
        var doubleValue: Double
        var wasReal: Bool
    }

    private static func readNumberToken(_ data: Data, at start: Int) throws -> (NumTok, Int) {
        var i = start
        guard i < data.count else { throw PDFSanitizerError.corrupt("number EOF") }
        let begin = i
        if data[i] == UInt8(ascii: "+") || data[i] == UInt8(ascii: "-") { i += 1 }
        var sawDigit = false
        var sawDot = false
        while i < data.count {
            let c = data[i]
            if c >= 48 && c <= 57 {
                sawDigit = true
                i += 1
            } else if c == UInt8(ascii: "."), !sawDot {
                sawDot = true
                i += 1
            } else {
                break
            }
        }
        guard sawDigit || sawDot else { throw PDFSanitizerError.corrupt("not a number") }
        let s = String(decoding: data[begin..<i], as: UTF8.self)
        if !sawDot, let v = Int(s) {
            return (NumTok(intValue: v, doubleValue: Double(v), wasReal: false), i)
        }
        guard let d = Double(s) else { throw PDFSanitizerError.corrupt("bad real") }
        return (NumTok(intValue: Int(d), doubleValue: d, wasReal: true), i)
    }

    private static func matchKeyword(_ data: Data, _ i: inout Int, _ word: String) -> Bool {
        let bytes = Array(word.utf8)
        guard i + bytes.count <= data.count else { return false }
        for (k, b) in bytes.enumerated() {
            if data[i + k] != b { return false }
        }
        let end = i + bytes.count
        // keyword boundary
        if end < data.count {
            let c = data[end]
            if !isDelimiter(c) && !isWhitespace(c) {
                // allow if next is delimiter; if alphanumeric, fail
                if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
                    return false
                }
            }
        }
        i = end
        return true
    }

    private static func peekObjectHeader(_ data: Data, at start: Int) -> (Int, Int)? {
        var i = start
        skipWhitespaceAndComments(data, &i)
        guard let (a, i1) = try? readNumberToken(data, at: i), let obj = a.intValue else { return nil }
        i = i1
        skipWhitespaceAndComments(data, &i)
        guard let (b, i2) = try? readNumberToken(data, at: i), let gen = b.intValue else { return nil }
        i = i2
        skipWhitespaceAndComments(data, &i)
        var j = i
        guard matchKeyword(data, &j, "obj") else { return nil }
        return (obj, gen)
    }

    private static func skipWhitespaceAndComments(_ data: Data, _ i: inout Int) {
        while i < data.count {
            let c = data[i]
            if isWhitespace(c) {
                i += 1
                continue
            }
            if c == UInt8(ascii: "%") {
                i += 1
                while i < data.count {
                    let ch = data[i]
                    i += 1
                    if ch == 10 || ch == 13 { break }
                }
                continue
            }
            break
        }
    }

    private static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        // ( ) < > [ ] { } / %
        c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93
            || c == 123 || c == 125 || c == 47 || c == 37
    }

    private static func ascii(_ c: UInt8) -> UInt8? { c }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 65 + 10
        case 97...102: return c - 97 + 10
        default: return nil
        }
    }

    private static func intFrom(_ v: PDFValue?) -> Int? {
        guard let v else { return nil }
        if case .int(let n) = v { return n }
        return nil
    }
}

// MARK: - Object loading

/// Loads objects on demand from the merged cross-reference entries. Loading is lazy because
/// objects depend on each other: a stream's `/Length` can be another object, and that object
/// can itself live inside an object stream.
private final class ObjectLoader {
    private let data: Data
    private let entries: [Int: PDFXRefEntry]
    private let budget: InflateBudget
    private var plain: [Int: PDFValue] = [:]
    private var containers: [Int: [(number: Int, value: PDFValue)]] = [:]
    /// Objects being parsed right now; meeting one again means a reference cycle.
    private var inProgress = Set<Int>()

    init(data: Data, entries: [Int: PDFXRefEntry], budget: InflateBudget) {
        self.data = data
        self.entries = entries
        self.budget = budget
    }

    /// The object's value, or `nil` if the table marks it free or does not list it.
    func value(of number: Int) throws -> PDFValue? {
        guard let entry = entries[number] else { return nil }
        switch entry.kind {
        case .free:
            return nil
        case .inUse(let offset):
            return try plainObject(number, at: offset, gen: entry.gen)
        case .compressed(let stream, let index):
            let members = try containerMembers(stream)
            guard index >= 0, index < members.count else {
                throw PDFSanitizerError.corrupt("object stream index past the end")
            }
            guard members[index].number == number else {
                throw PDFSanitizerError.corrupt("object stream member does not match the cross-reference entry")
            }
            return members[index].value
        }
    }

    private func plainObject(_ number: Int, at offset: Int, gen: Int) throws -> PDFValue {
        if let loaded = plain[number] { return loaded }
        guard offset >= 0, offset < data.count else {
            throw PDFSanitizerError.corrupt("object offset outside the file")
        }
        guard inProgress.insert(number).inserted else {
            throw PDFSanitizerError.corrupt("circular object reference")
        }
        defer { inProgress.remove(number) }
        let value = try PDFParser.parseIndirectObject(
            data,
            at: offset,
            expectObj: number,
            expectGen: gen,
            lengthResolver: { [unowned self] ref in
                guard let length = try? self.value(of: ref.obj), case .int(let n) = length else {
                    return nil
                }
                return n
            }
        )
        plain[number] = value
        return value
    }

    private func containerMembers(_ stream: Int) throws -> [(number: Int, value: PDFValue)] {
        if let loaded = containers[stream] { return loaded }
        // An object stream is always a plain object; one stored inside another is invalid.
        guard let entry = entries[stream], case .inUse(let offset) = entry.kind else {
            throw PDFSanitizerError.corrupt("object stream is not stored as a plain object")
        }
        guard case .stream(let dict, let payload) = try plainObject(stream, at: offset, gen: entry.gen) else {
            throw PDFSanitizerError.corrupt("compressed object refers to something that is not a stream")
        }
        let members = try PDFObjectStream.members(dict: dict, data: payload, budget: budget)
        containers[stream] = members
        return members
    }
}
