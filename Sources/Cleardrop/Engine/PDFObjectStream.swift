import Foundation

/// An object stream: several non-stream objects stored together in one compressed stream.
enum PDFObjectStream {
    /// The objects in the stream, in stream order, with the object number each one declares.
    static func members(
        dict: [String: PDFValue],
        data: Data,
        budget: InflateBudget
    ) throws -> [(number: Int, value: PDFValue)] {
        guard case .some(.name(let type)) = dict["Type"], type == "ObjStm" else {
            throw PDFSanitizerError.corrupt("compressed object refers to something that is not an object stream")
        }
        guard case .some(.int(let count)) = dict["N"], count >= 0,
              count <= PDFSanitizer.effectiveMaxObjectCount
        else {
            throw PDFSanitizerError.corrupt("object stream /N")
        }
        let decoded = try StructuralStream.decode(dict: dict, data: data, budget: budget)
        guard case .some(.int(let first)) = dict["First"], first >= 0, first <= decoded.count else {
            throw PDFSanitizerError.corrupt("object stream /First")
        }

        // Header: N pairs of "object number, offset relative to /First".
        let header = try PDFParser.readIntegers(decoded.prefix(first), count: count * 2)
        var members: [(number: Int, value: PDFValue)] = []
        members.reserveCapacity(count)
        for i in 0..<count {
            let number = header[i * 2]
            let offset = header[i * 2 + 1]
            guard number >= 0, offset >= 0, first + offset < decoded.count else {
                throw PDFSanitizerError.corrupt("object stream offset past the end")
            }
            let value = try PDFParser.parseObjectStreamMember(decoded, at: first + offset)
            members.append((number, value))
        }
        return members
    }
}
