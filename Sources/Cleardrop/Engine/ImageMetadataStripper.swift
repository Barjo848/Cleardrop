import Foundation

/// Scrub identifying APP segments from raw JPEG (DCTDecode) payloads.
/// Removes APP1 (EXIF / XMP) and APP13 (Photoshop/IPTC). Other segments copy-through.
enum ImageMetadataStripper {
    /// If `data` is a JPEG, return scrubbed bytes; otherwise return unchanged.
    static func scrubJPEGIfNeeded(_ data: Data) -> Data {
        guard data.count >= 4,
              data[0] == 0xFF, data[1] == 0xD8
        else {
            return data
        }
        return scrubJPEG(data)
    }

    /// True when stream dict uses DCTDecode (possibly inside a filter array).
    static func isDCTDecode(_ dict: [String: PDFValue]) -> Bool {
        guard let filter = dict["Filter"] else { return false }
        return filterContainsDCTDecode(filter)
    }

    // MARK: - JPEG

    private static func scrubJPEG(_ data: Data) -> Data {
        var out = Data()
        out.append(0xFF)
        out.append(0xD8)
        var i = 2
        let n = data.count

        while i < n {
            // Skip fill bytes 0xFF
            if data[i] != 0xFF {
                // Entropy-coded segment without marker — copy rest
                out.append(data.subdata(in: i..<n))
                break
            }
            // Consume one or more 0xFF
            while i < n && data[i] == 0xFF {
                i += 1
            }
            guard i < n else { break }
            let marker = data[i]
            i += 1

            // Standalone markers without length
            if marker == 0x00 {
                // Escaped 0xFF 0x00 in entropy — shouldn't appear before SOS in well-formed files
                out.append(0xFF)
                out.append(0x00)
                continue
            }
            if marker == 0xD9 { // EOI
                out.append(0xFF)
                out.append(0xD9)
                break
            }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                // TEM / RSTn
                out.append(0xFF)
                out.append(marker)
                continue
            }
            if marker == 0xDA { // SOS — copy rest of file (includes entropy + EOI)
                out.append(0xFF)
                out.append(0xDA)
                if i < n {
                    out.append(data.subdata(in: i..<n))
                }
                break
            }

            // Markers with 2-byte length
            guard i + 2 <= n else { break }
            let len = (Int(data[i]) << 8) | Int(data[i + 1])
            guard len >= 2, i + len <= n else {
                // Corrupt — copy remainder
                out.append(0xFF)
                out.append(marker)
                out.append(data.subdata(in: i..<n))
                break
            }
            let segmentEnd = i + len
            let payloadStart = i + 2
            let payload = data.subdata(in: payloadStart..<segmentEnd)

            // Drop APP1 (EXIF / XMP) and APP13 (Photoshop / IPTC)
            if marker == 0xE1 || marker == 0xED {
                _ = payload // intentionally discarded
                i = segmentEnd
                continue
            }

            out.append(0xFF)
            out.append(marker)
            out.append(data.subdata(in: i..<segmentEnd))
            i = segmentEnd
        }

        // Ensure SOI still present; if scrubbing removed everything pathological, fall back
        if out.count < 4 {
            return data
        }
        return out
    }

    // MARK: - Filter helpers

    private static func filterContainsDCTDecode(_ filter: PDFValue) -> Bool {
        switch filter {
        case .name(let n):
            return n == "DCTDecode"
        case .array(let items):
            return items.contains { filterContainsDCTDecode($0) }
        default:
            return false
        }
    }
}
