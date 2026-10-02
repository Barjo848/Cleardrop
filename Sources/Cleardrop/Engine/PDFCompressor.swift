import Foundation
import zlib

/// Applies compression profiles to a parsed object graph.
/// Level 1+: lossless Flate re-pack of eligible non-image streams.
/// Levels 2–4: lossy image recompression.
enum PDFCompressor {
    /// Approximate dict overhead of adding `/Filter /FlateDecode` (never-worsen check).
    private static let filterOverheadBytes = 48

    /// What a compression pass changed.
    struct Outcome: Sendable, Equatable {
        var imagesRecompressed = 0
        var streamsPacked = 0
    }

    /// Mutate `graph` according to `profile`. Never enlarges a stream payload.
    @discardableResult
    static func apply(to graph: inout PDFDocumentGraph, profile: CompressionProfile) -> Outcome {
        var outcome = Outcome()
        // Lossy images first (may replace DCT streams), then lossless Flate on remaining raw streams.
        if profile.isLossy {
            outcome.imagesRecompressed = ImageRecompressor.recompressImages(in: &graph, profile: profile)
        }
        if profile.reflattenStreams {
            outcome.streamsPacked = reflattenEligibleStreams(in: &graph)
        }
        return outcome
    }

    // MARK: - Lossless Flate

    /// Compress raw (unfiltered) non-image streams with zlib/Flate when smaller.
    /// - Returns: how many streams were packed.
    private static func reflattenEligibleStreams(in graph: inout PDFDocumentGraph) -> Int {
        var packed = 0
        let keys = Array(graph.objects.keys)
        for objNum in keys {
            guard var entry = graph.objects[objNum] else { continue }
            guard case .stream(var dict, let data) = entry.value else { continue }
            guard shouldAttemptFlate(dict: dict, data: data) else { continue }

            guard let compressed = zlibCompress(data) else { continue }
            guard compressed.count + filterOverheadBytes < data.count else { continue }
            guard let roundTrip = zlibDecompress(compressed, expectedCount: data.count),
                  roundTrip == data
            else { continue }

            dict["Filter"] = .name("FlateDecode")
            dict["Length"] = .int(compressed.count)
            dict.removeValue(forKey: "DecodeParms")
            dict.removeValue(forKey: "DP")

            entry.value = .stream(dict: dict, data: compressed)
            graph.objects[objNum] = entry
            packed += 1
        }
        return packed
    }

    private static func shouldAttemptFlate(dict: [String: PDFValue], data: Data) -> Bool {
        guard data.count >= 64 else { return false }

        if case .name(let t) = dict["Type"], t == "Metadata" { return false }
        if case .name(let t) = dict["Type"], t == "XObject",
           case .name(let s) = dict["Subtype"], s == "Image"
        {
            return false
        }
        if ImageMetadataStripper.isDCTDecode(dict) { return false }

        // Skip anything that already has a filter (avoid double-Flate without inflate).
        if dict["Filter"] != nil { return false }
        if dict["F"] != nil { return false }

        return true
    }

    /// Standard zlib (RFC 1950) for PDF `/Filter /FlateDecode` via libz `compress2`.
    static func zlibCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return data }
        let bound = compressBound(uLong(data.count))
        var destLen = uLongf(bound)
        var dest = [UInt8](repeating: 0, count: Int(bound))
        let status = data.withUnsafeBytes { raw -> Int32 in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return Z_BUF_ERROR }
            return compress2(&dest, &destLen, src, uLong(data.count), Z_DEFAULT_COMPRESSION)
        }
        guard status == Z_OK, destLen > 0, Int(destLen) < data.count else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }

    /// Inflate what `zlibCompress` produced, to confirm it reads back as `expectedCount` bytes.
    static func zlibDecompress(_ data: Data, expectedCount: Int) -> Data? {
        try? Inflate.inflate(data, budget: InflateBudget(expectedCount))
    }
}
