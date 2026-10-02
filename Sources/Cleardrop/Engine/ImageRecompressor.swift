import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Lossy recompression of PDF image XObjects.
/// Never rasterizes whole pages — only individual image streams, and only the narrow kind
/// described by `isEligible`. Everything else is left byte for byte as it was.
enum ImageRecompressor {
    /// Re-encode eligible image streams per profile. Never enlarges a stream.
    /// - Returns: how many images were replaced.
    @discardableResult
    static func recompressImages(in graph: inout PDFDocumentGraph, profile: CompressionProfile) -> Int {
        guard profile.isLossy else { return 0 }
        let maskTargets = maskTargetObjects(in: graph)
        var replaced = 0
        for objNum in Array(graph.objects.keys) {
            guard !maskTargets.contains(objNum), var entry = graph.objects[objNum] else { continue }
            guard case .stream(let dict, let data) = entry.value else { continue }
            guard let result = recompressStream(dict: dict, data: data, profile: profile) else {
                continue
            }
            entry.value = .stream(dict: result.dict, data: result.data)
            graph.objects[objNum] = entry
            replaced += 1
        }
        return replaced
    }

    /// Images in the document, and how many of them the lossy levels are able to re-encode.
    static func imageCounts(in graph: PDFDocumentGraph) -> (total: Int, eligible: Int) {
        let maskTargets = maskTargetObjects(in: graph)
        var total = 0
        var eligible = 0
        for (objNum, entry) in graph.objects {
            guard case .stream(let dict, let data) = entry.value, isImage(dict) else { continue }
            total += 1
            if !maskTargets.contains(objNum), isEligible(dict: dict, data: data) {
                eligible += 1
            }
        }
        return (total, eligible)
    }

    // MARK: - Eligibility

    private static func isImage(_ dict: [String: PDFValue]) -> Bool {
        if case .some(.name(let subtype)) = dict["Subtype"], subtype == "Image" { return true }
        return false
    }

    /// Objects that another image uses as its soft mask or stencil mask. Their samples are
    /// transparency, not a picture, so they are never re-encoded.
    private static func maskTargetObjects(in graph: PDFDocumentGraph) -> Set<Int> {
        var targets = Set<Int>()
        for (_, entry) in graph.objects {
            guard let dict = PDFGraphInspect.dict(of: entry.value) else { continue }
            for key in ["SMask", "Mask"] {
                if case .some(.ref(let ref)) = dict[key] { targets.insert(ref.obj) }
            }
        }
        return targets
    }

    /// The only images that are re-encoded: a plain JPEG (`DCTDecode` as the sole filter) in
    /// `DeviceRGB` or `DeviceGray`, 8 bits per component, with no mask, no stencil use and no
    /// `/Decode` array. CMYK and calibrated or ICC colour are excluded because re-encoding
    /// would have to change the colour model.
    static func isEligible(dict: [String: PDFValue], data: Data) -> Bool {
        guard isImage(dict), data.count >= 128 else { return false }

        switch dict["Filter"] {
        case .some(.name(let name)):
            guard name == "DCTDecode" else { return false }
        case .some(.array(let items)):
            guard items == [.name("DCTDecode")] else { return false }
        default:
            return false
        }
        guard data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return false }

        guard case .some(.name(let colorSpace)) = dict["ColorSpace"],
              colorSpace == "DeviceRGB" || colorSpace == "DeviceGray"
        else { return false }

        if let bits = dict["BitsPerComponent"], bits != .int(8) { return false }
        for key in ["SMask", "Mask", "Decode", "SMaskInData"] where dict[key] != nil {
            return false
        }
        if let stencil = dict["ImageMask"], stencil != .bool(false) { return false }
        return true
    }

    // MARK: - Per-stream

    private static func recompressStream(
        dict: [String: PDFValue],
        data: Data,
        profile: CompressionProfile
    ) -> (dict: [String: PDFValue], data: Data)? {
        guard isEligible(dict: dict, data: data) else { return nil }
        guard case .some(.int(let width)) = dict["Width"], case .some(.int(let height)) = dict["Height"],
              width > 0, height > 0
        else { return nil }

        guard let cgImage = decodeImage(data: data) else { return nil }
        // The JPEG must be what the dictionary says it is.
        let declaredGray = dict["ColorSpace"] == .name("DeviceGray")
        guard cgImage.width == width, cgImage.height == height,
              cgImage.colorSpace?.model == (declaredGray ? .monochrome : .rgb)
        else { return nil }

        let (targetWidth, targetHeight) = targetPixelSize(width: width, height: height, profile: profile)
        let quality = profile.jpegQuality ?? 0.75
        let gray = declaredGray || (profile.convertNearGrayToGray && isNearlyGray(cgImage))

        guard let encoded = encodeJPEG(
            image: cgImage,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            quality: quality,
            gray: gray
        ) else { return nil }
        // The encoder writes its own Exif and Photoshop blocks; they carry nothing useful.
        let jpeg = ImageMetadataStripper.scrubJPEGIfNeeded(encoded)

        // Never worsen stream payload size
        guard jpeg.count < data.count else { return nil }

        var out = dict
        out["Width"] = .int(targetWidth)
        out["Height"] = .int(targetHeight)
        out["BitsPerComponent"] = .int(8)
        out["Filter"] = .name("DCTDecode")
        out["Length"] = .int(jpeg.count)
        out["ColorSpace"] = .name(gray ? "DeviceGray" : "DeviceRGB")
        out.removeValue(forKey: "DecodeParms")
        return (out, jpeg)
    }

    // MARK: - Geometry

    /// Scale so the longer side is at most `profile.maxImageEdge`. Smaller images keep their size.
    static func targetPixelSize(width: Int, height: Int, profile: CompressionProfile) -> (Int, Int) {
        guard let cap = profile.maxImageEdge, cap > 0 else { return (width, height) }
        let longEdge = max(width, height)
        guard longEdge > cap else { return (width, height) }
        let scale = Double(cap) / Double(longEdge)
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        return (min(newWidth, cap), min(newHeight, cap))
    }

    // MARK: - Decode / encode

    private static func decodeImage(data: Data) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        else {
            return nil
        }
        return img
    }

    private static func encodeJPEG(
        image: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        quality: Double,
        gray: Bool
    ) -> Data? {
        let q = min(1.0, max(0.05, quality))
        // Always draw into a context of the colour model that will be declared, so the
        // JPEG's component count and the dictionary's /ColorSpace cannot disagree.
        guard let scaled = redraw(image, width: targetWidth, height: targetHeight, gray: gray) else {
            return nil
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q,
        ]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func redraw(
        _ image: CGImage,
        width: Int,
        height: Int,
        gray: Bool
    ) -> CGImage? {
        // Draw in the image's own colour space where the model matches, so sample values are
        // resampled but not colour-converted. A PDF viewer reads these samples as device
        // colour and ignores any profile inside the JPEG; converting them would shift colours.
        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        if gray {
            if let own = image.colorSpace, own.model == .monochrome {
                colorSpace = own
            } else {
                colorSpace = CGColorSpaceCreateDeviceGray()
            }
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        } else {
            if let own = image.colorSpace, own.model == .rgb {
                colorSpace = own
            } else {
                colorSpace = CGColorSpaceCreateDeviceRGB()
            }
            bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func isNearlyGray(_ image: CGImage) -> Bool {
        // Cheap sample: draw tiny thumbnail and check chroma
        guard let thumb = redraw(image, width: 16, height: 16, gray: false) else {
            return false
        }
        let w = thumb.width
        let h = thumb.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        var chroma: Int = 0
        let n = w * h
        for i in 0..<n {
            let o = i * 4
            let r = Int(buf[o])
            let g = Int(buf[o + 1])
            let b = Int(buf[o + 2])
            chroma += abs(r - g) + abs(g - b) + abs(r - b)
        }
        let avg = Double(chroma) / Double(max(1, n))
        return avg < 12 // mostly gray
    }
}
