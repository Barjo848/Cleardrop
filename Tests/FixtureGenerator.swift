import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Builds test PDFs in memory. Nothing here is written into the repository:
/// a fixture is committed only when it is small, stable and hand-written.
enum FixtureGenerator {
    // MARK: - Classic PDF assembly

    /// Assemble a classic-xref PDF from numbered object bodies.
    /// `trailerExtra` is spliced into the trailer dictionary after `/Root 1 0 R`.
    static func classicPDF(
        objects: [(number: Int, body: Data)],
        trailerExtra: String = "",
        version: String = "1.4",
        phantomInUse: Set<Int> = []
    ) -> Data {
        var out = Data("%PDF-\(version)\n".utf8)
        var offsets: [Int: Int] = [:]
        for object in objects {
            offsets[object.number] = out.count
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        let size = max(offsets.keys.max() ?? 0, phantomInUse.max() ?? 0) + 1
        out.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for number in 1..<size {
            if let offset = offsets[number] {
                out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else if phantomInUse.contains(number) {
                // What Quartz writes for an object number it never used: in use, at offset 0.
                out.append(Data("0000000000 00000 n \n".utf8))
            } else {
                out.append(Data("0000000000 00000 f \n".utf8))
            }
        }
        out.append(Data("trailer\n<< /Size \(size) /Root 1 0 R \(trailerExtra) >>\n".utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    static func streamObject(dict: String, payload: Data) -> Data {
        var body = Data("<< /Length \(payload.count) \(dict) >>\nstream\n".utf8)
        body.append(payload)
        body.append(Data("\nendstream".utf8))
        return body
    }

    // MARK: - One text page

    /// Objects 1–5 of a one-page document that shows `text`:
    /// catalog, page tree, page, content stream, font.
    static func onePageObjects(
        text: String = "Hello",
        catalogExtra: String = "",
        pageExtra: String = ""
    ) -> [(number: Int, body: Data)] {
        let content = Data("BT /F1 12 Tf 72 700 Td (\(text)) Tj ET".utf8)
        return [
            (1, Data("<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>".utf8)),
            (2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)),
            (3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> \(pageExtra) >>".utf8)),
            (4, streamObject(dict: "", payload: content)),
            (5, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)),
        ]
    }

    // MARK: - Incremental updates

    enum PrevTarget {
        /// The section the base file's `startxref` points at, as a real incremental save does.
        case previousSection
        /// The new section itself: a one-step cycle.
        case itself
        case offset(Int)
    }

    static func lastStartXRef(of pdf: Data) -> Int {
        guard let marker = pdf.range(of: Data("startxref".utf8), options: .backwards) else { return 0 }
        let tail = String(decoding: pdf[marker.upperBound...], as: UTF8.self)
        let digits = tail.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// Append an incremental update: new or replaced objects, then an `xref` section that lists
    /// only those objects and points back with `/Prev`.
    static func appendingUpdate(
        to base: Data,
        objects: [(number: Int, body: Data)],
        size: Int,
        trailerExtra: String = "",
        prev: PrevTarget = .previousSection
    ) -> Data {
        var out = base
        var offsets: [(number: Int, offset: Int)] = []
        for object in objects.sorted(by: { $0.number < $1.number }) {
            offsets.append((object.number, out.count))
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        out.append(Data("xref\n0 1\n0000000000 65535 f \n".utf8))
        for entry in offsets {
            out.append(Data("\(entry.number) 1\n".utf8))
            out.append(Data(String(format: "%010d 00000 n \n", entry.offset).utf8))
        }
        let prevOffset: Int
        switch prev {
        case .previousSection: prevOffset = lastStartXRef(of: base)
        case .itself: prevOffset = xrefOffset
        case .offset(let value): prevOffset = value
        }
        out.append(Data("trailer\n<< /Size \(size) /Root 1 0 R \(trailerExtra) /Prev \(prevOffset) >>\n".utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    /// A one-page file saved once, then updated to add a second page and an Info dictionary.
    /// Every object of the first page lives only in the older section.
    static let twoSectionPDF: Data = {
        let base = classicPDF(objects: onePageObjects(text: "Hello"))
        let secondContent = Data("BT /F1 12 Tf 72 700 Td (Second) Tj ET".utf8)
        return appendingUpdate(
            to: base,
            objects: [
                (2, Data("<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>".utf8)),
                (6, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>".utf8)),
                (7, streamObject(dict: "", payload: secondContent)),
                (8, Data("<< /Author (\(CleardropTests.plantedAuthor)) >>".utf8)),
            ],
            size: 9,
            trailerExtra: "/Info 8 0 R"
        )
    }()

    /// Two sections whose `/Prev` entries point at each other.
    static let mutualPrevCyclePDF: Data = {
        let placeholder = "0000000000"
        let base = classicPDF(objects: onePageObjects(), trailerExtra: "/Prev \(placeholder)")
        var updated = appendingUpdate(
            to: base,
            objects: [(6, Data("<< /Note (update) >>".utf8))],
            size: 7
        )
        let newest = lastStartXRef(of: updated)
        if let range = updated.range(of: Data("/Prev \(placeholder)".utf8)) {
            updated.replaceSubrange(range, with: Data(String(format: "/Prev %010d", newest).utf8))
        }
        return updated
    }()

    // MARK: - Metadata that is easy to leave behind

    /// Info whose Author is a separate string object and whose custom key points at a
    /// dictionary object. Neither is referenced from anywhere else.
    static let indirectInfoPDF: Data = {
        var objects = onePageObjects()
        objects.append((6, Data("<< /Author 7 0 R /Custom 8 0 R >>".utf8)))
        objects.append((7, Data("(\(CleardropTests.plantedIndirectAuthor))".utf8)))
        objects.append((8, Data("<< /Nested (\(CleardropTests.plantedNestedInfo)) >>".utf8)))
        return classicPDF(objects: objects, trailerExtra: "/Info 6 0 R")
    }()

    /// PieceInfo on a page (pointing at a separate object) and inline on a form XObject.
    static let pagePieceInfoPDF: Data = {
        var objects = onePageObjects(
            pageExtra: "/PieceInfo 6 0 R /LastModified (D:20200101000000Z)"
        )
        objects.append((6, Data("<< /App << /Private (\(CleardropTests.plantedPagePiece)) /LastModified (D:20200101000000Z) >> >>".utf8)))
        objects.append((7, streamObject(
            dict: "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /PieceInfo << /App << /Private (\(CleardropTests.plantedPagePiece)) >> >> /LastModified (D:20200101000000Z)",
            payload: Data("0 0 10 10 re f".utf8)
        )))
        // Reference the form from the page so it is live content.
        objects[2] = (3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 7 0 R >> >> /PieceInfo 6 0 R /LastModified (D:20200101000000Z) >>".utf8))
        return classicPDF(objects: objects)
    }()

    /// A complete one-page document plus an object nothing points at.
    static let orphanObjectPDF: Data = {
        var objects = onePageObjects()
        objects.append((6, Data("<< /Leftover (\(CleardropTests.plantedOrphan)) >>".utf8)))
        return classicPDF(objects: objects)
    }()

    /// Info that points at the page's font object, so detaching Info must not delete it.
    static let sharedWithInfoPDF: Data = {
        var objects = onePageObjects()
        objects.append((6, Data("<< /Author (\(CleardropTests.plantedAuthor)) /Custom 5 0 R >>".utf8)))
        return classicPDF(objects: objects, trailerExtra: "/Info 6 0 R")
    }()

    // MARK: - Things that stay

    static let residualScriptMark = "RESIDUAL_SCRIPT_MARK"
    static let residualAttachmentMark = "RESIDUAL_ATTACHMENT_MARK"
    static let residualProfileMark = "RESIDUAL_PROFILE_MARK"

    /// A page with an open-action script, an attached file and an output intent with a
    /// colour profile, plus an Info author. Only the author is removable.
    static let residualsPDF: Data = {
        var objects = onePageObjects(
            catalogExtra: "/OpenAction 6 0 R /Names << /EmbeddedFiles << /Names [(note.txt) 7 0 R] >> >> /OutputIntents [9 0 R]"
        )
        objects.append((6, Data("<< /S /JavaScript /JS (var mark = '\(residualScriptMark)';) >>".utf8)))
        objects.append((7, Data("<< /Type /Filespec /F (note.txt) /EF << /F 8 0 R >> >>".utf8)))
        objects.append((8, streamObject(dict: "/Type /EmbeddedFile", payload: Data(residualAttachmentMark.utf8))))
        objects.append((9, Data("<< /Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (Custom) /DestOutputProfile 10 0 R >>".utf8)))
        objects.append((10, streamObject(dict: "/N 3", payload: Data(residualProfileMark.utf8))))
        objects.append((11, Data("<< /Author (\(CleardropTests.plantedAuthor)) >>".utf8)))
        return classicPDF(objects: objects, trailerExtra: "/Info 11 0 R")
    }()

    /// A script that nothing references: it is dropped on save, so it does not stay.
    static let unreachableScriptPDF: Data = {
        var objects = onePageObjects()
        objects.append((6, Data("<< /S /JavaScript /JS (var mark = '\(residualScriptMark)';) >>".utf8)))
        return classicPDF(objects: objects)
    }()

    // MARK: - Signature fields

    /// A form with a signature field. `value` is spliced into the field dictionary
    /// (for example "/V 7 0 R"), and `extra` adds objects such as the signature dictionary.
    static func signatureFieldPDF(value: String = "", extra: [(number: Int, body: Data)] = []) -> Data {
        var objects = onePageObjects(
            catalogExtra: "/AcroForm << /Fields [6 0 R] /SigFlags 0 >>",
            pageExtra: "/Annots [6 0 R]"
        )
        objects.append((6, Data("<< /FT /Sig /T (Signature1) /Type /Annot /Subtype /Widget /Rect [0 0 0 0] /P 3 0 R \(value) >>".utf8)))
        objects.append(contentsOf: extra)
        objects.append((20, Data("<< /Author (\(CleardropTests.plantedAuthor)) >>".utf8)))
        return classicPDF(objects: objects, trailerExtra: "/Info 20 0 R")
    }

    static let signatureDictionary = Data(
        "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 1 2 3] /Contents <3080> >>".utf8
    )

    // MARK: - Photo page

    static let photoWidth = 1200
    static let photoHeight = 900

    /// One page with a large noisy JPEG and a line of text, plus a planted Info author.
    /// The JPEG is encoded by ImageIO, so its exact bytes depend on the OS;
    /// tests assert its properties, never its bytes.
    static let photoPDF: Data = {
        let jpeg = noisyJPEG(width: photoWidth, height: photoHeight, quality: 1.0)
        let content = Data("q 500 0 0 400 50 200 cm /Im0 Do Q\nBT /F1 18 Tf 50 700 Td (Photo page) Tj ET".utf8)
        return classicPDF(
            objects: [
                (1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)),
                (2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)),
                (3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 6 0 R >> /XObject << /Im0 5 0 R >> >> >>".utf8)),
                (4, streamObject(dict: "", payload: content)),
                (5, streamObject(
                    dict: "/Type /XObject /Subtype /Image /Width \(photoWidth) /Height \(photoHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
                    payload: jpeg
                )),
                (6, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)),
                (7, Data("<< /Author (\(CleardropTests.plantedAuthor)) /Producer (Fixture) >>".utf8)),
            ],
            trailerExtra: "/Info 7 0 R"
        )
    }()

    // MARK: - Image pages

    enum ImageModel {
        case rgb, gray, cmyk
    }

    /// One page that draws a single image XObject (object 5). `colorSpace` and `imageExtra`
    /// are written into the image dictionary as given.
    static func imagePDF(
        jpeg: Data,
        width: Int,
        height: Int,
        colorSpace: String,
        imageExtra: String = "",
        extraObjects: [(number: Int, body: Data)] = []
    ) -> Data {
        let content = Data("q 500 0 0 400 50 200 cm /Im0 Do Q".utf8)
        var objects: [(number: Int, body: Data)] = [
            (1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)),
            (2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)),
            (3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>".utf8)),
            (4, streamObject(dict: "", payload: content)),
            (5, streamObject(
                dict: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace \(colorSpace) /BitsPerComponent 8 /Filter /DCTDecode \(imageExtra)",
                payload: jpeg
            )),
        ]
        objects.append(contentsOf: extraObjects)
        return classicPDF(objects: objects)
    }

    /// A deterministic noisy JPEG in the given colour model.
    static func patternJPEG(width: Int, height: Int, model: ImageModel, quality: Double = 0.95) -> Data {
        let colorSpace: CGColorSpace
        let components: Int
        let bitmapInfo: UInt32
        switch model {
        case .rgb:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            components = 4
            bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        case .gray:
            colorSpace = CGColorSpaceCreateDeviceGray()
            components = 1
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        case .cmyk:
            colorSpace = CGColorSpaceCreateDeviceCMYK()
            components = 4
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        }
        var pixels = [UInt8](repeating: 255, count: width * height * components)
        var seed: UInt64 = 0xC1EA_0D20_5EED_0002
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int((seed >> 33) % 61) - 30
                let o = (y * width + x) * components
                func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
                switch model {
                case .gray:
                    pixels[o] = clamp((x + y) * 255 / (width + height) + noise)
                case .rgb:
                    pixels[o] = clamp(x * 255 / width + noise)
                    pixels[o + 1] = clamp(y * 255 / height + noise)
                    pixels[o + 2] = clamp(128 + noise)
                case .cmyk:
                    pixels[o] = clamp(x * 255 / width + noise)
                    pixels[o + 1] = clamp(y * 255 / height + noise)
                    pixels[o + 2] = clamp(90 + noise)
                    pixels[o + 3] = 20
                }
            }
        }
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * components, space: colorSpace, bitmapInfo: bitmapInfo
            )!.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Number of colour components a JPEG declares in its frame header.
    static func jpegComponentCount(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var i = 2
        while i + 9 < bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 { return Int(bytes[i + 9]) }
            if marker == 0xDA { return nil }
            i += 2 + length
        }
        return nil
    }

    /// Deterministic gradient with per-pixel noise, so the JPEG is large and shrinks when re-encoded.
    static func noisyJPEG(width: Int, height: Int, quality: Double) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 0x5EED_C1EA_0D20_0001
        func noise() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % 97) - 48
        }
        func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                pixels[o] = clamp(x * 255 / width + noise())
                pixels[o + 1] = clamp(y * 255 / height + noise())
                pixels[o + 2] = clamp((x + y) * 255 / (width + height) + noise())
            }
        }
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            return context.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        // Ask ImageIO for the Exif and IPTC blocks a camera or editor would leave behind.
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "fixture"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "fixture"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
