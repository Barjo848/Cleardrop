import Foundation
import zlib

/// How many more bytes the parser may inflate for one document. Shared across every
/// structural stream so a file cannot expand without limit.
final class InflateBudget {
    private(set) var remaining: Int

    init(_ bytes: Int) {
        remaining = max(0, bytes)
    }

    func spend(_ bytes: Int) throws {
        guard bytes <= remaining else {
            throw PDFSanitizerError.unsupportedStructure("decompressed data too large")
        }
        remaining -= bytes
    }
}

enum Inflate {
    /// Inflate zlib (RFC 1950) data, refusing to produce more than the budget allows.
    static func inflate(_ data: Data, budget: InflateBudget) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PDFSanitizerError.corrupt("inflate setup failed")
        }
        defer { inflateEnd(&stream) }

        var out = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw PDFSanitizerError.corrupt("bad Flate data")
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    try budget.spend(produced)
                    out.append(chunk, count: produced)
                }
                if status == Z_STREAM_END { break }
                // Z_BUF_ERROR here means the input ended before the stream did.
                guard status == Z_OK else {
                    throw PDFSanitizerError.corrupt("bad or truncated Flate data")
                }
            }
        }
        return out
    }
}

/// Decoding for the two stream kinds the parser has to read: cross-reference streams and
/// object streams. Page content, fonts and images are never decoded here.
enum StructuralStream {
    static func decode(
        dict: [String: PDFValue],
        data: Data,
        budget: InflateBudget
    ) throws -> Data {
        let filters: [String]
        switch dict["Filter"] {
        case nil, .some(.null):
            filters = []
        case .some(.name(let name)):
            filters = [name]
        case .some(.array(let items)):
            filters = try items.map { item -> String in
                guard case .name(let name) = item else {
                    throw PDFSanitizerError.corrupt("bad /Filter")
                }
                return name
            }
        default:
            throw PDFSanitizerError.corrupt("bad /Filter")
        }

        guard !filters.isEmpty else {
            try budget.spend(data.count)
            return data
        }
        guard filters == ["FlateDecode"] else {
            throw PDFSanitizerError.unsupportedStructure(
                "filter \(filters.joined(separator: "+")) on a structural stream"
            )
        }

        var parms: [String: PDFValue] = [:]
        switch dict["DecodeParms"] {
        case .some(.dict(let d)):
            parms = d
        case .some(.array(let items)):
            if case .some(.dict(let d)) = items.first { parms = d }
        default:
            break
        }

        let inflated = try Inflate.inflate(data, budget: budget)
        let predictor = int(parms["Predictor"]) ?? 1
        switch predictor {
        case 1:
            return inflated
        case 10...15:
            let colors = int(parms["Colors"]) ?? 1
            let bits = int(parms["BitsPerComponent"]) ?? 8
            let columns = int(parms["Columns"]) ?? 1
            guard bits == 8, colors >= 1, colors <= 4, columns >= 1, columns <= 4096 else {
                throw PDFSanitizerError.unsupportedStructure("predictor parameters on a structural stream")
            }
            return try undoPNGPredictor(inflated, rowBytes: columns * colors, pixelBytes: colors)
        default:
            throw PDFSanitizerError.unsupportedStructure("predictor \(predictor) on a structural stream")
        }
    }

    /// Reverse the PNG row filters (None, Sub, Up, Average, Paeth).
    static func undoPNGPredictor(_ data: Data, rowBytes: Int, pixelBytes: Int) throws -> Data {
        let stride = rowBytes + 1
        guard data.count % stride == 0 else {
            throw PDFSanitizerError.corrupt("predictor data is not a whole number of rows")
        }
        let input = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(input.count / stride * rowBytes)
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var row = [UInt8](repeating: 0, count: rowBytes)

        var offset = 0
        while offset < input.count {
            let filter = input[offset]
            for i in 0..<rowBytes {
                let raw = input[offset + 1 + i]
                let left = i >= pixelBytes ? row[i - pixelBytes] : 0
                let up = previous[i]
                let upLeft = i >= pixelBytes ? previous[i - pixelBytes] : 0
                switch filter {
                case 0: row[i] = raw
                case 1: row[i] = raw &+ left
                case 2: row[i] = raw &+ up
                case 3: row[i] = raw &+ UInt8((Int(left) + Int(up)) / 2)
                case 4:
                    let p = Int(left) + Int(up) - Int(upLeft)
                    let pa = abs(p - Int(left)), pb = abs(p - Int(up)), pc = abs(p - Int(upLeft))
                    let predicted = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                    row[i] = raw &+ predicted
                default:
                    throw PDFSanitizerError.corrupt("unknown predictor row filter")
                }
            }
            out.append(contentsOf: row)
            previous = row
            offset += stride
        }
        return Data(out)
    }

    private static func int(_ value: PDFValue?) -> Int? {
        if case .some(.int(let n)) = value { return n }
        return nil
    }
}
