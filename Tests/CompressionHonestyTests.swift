import Foundation
import PDFKit

/// The compression labels describe what the engine does, and images the labels do not
/// mention are left byte for byte.
extension CleardropTests {
    /// The image XObject (object 5 of `FixtureGenerator.imagePDF`) after cleaning at `level`.
    static func imageObject(_ pdf: Data, level: Int, number: Int = 5) throws -> (dict: [String: PDFValue], data: Data) {
        let out = try PDFSanitizer.sanitize(
            data: pdf, options: .default, compression: CompressionProfiles.profile(for: level)
        )
        let graph = try PDFParser.parse(out)
        guard case .some(.stream(let dict, let data)) = graph.objects[number]?.value else {
            throw PDFSanitizerError.corrupt("test: image object \(number) missing")
        }
        return (dict, data)
    }

    static func expectUntouchedAtEveryLevel(_ pdf: Data, _ what: String, number: Int = 5) {
        do {
            let reference = try imageObject(pdf, level: 0, number: number)
            for level in 1...4 {
                let image = try imageObject(pdf, level: level, number: number)
                expect(image.data == reference.data, "\(what) L\(level): image bytes unchanged")
                expect(image.dict["ColorSpace"] == reference.dict["ColorSpace"], "\(what) L\(level): /ColorSpace unchanged")
                expect(image.dict["Width"] == reference.dict["Width"], "\(what) L\(level): /Width unchanged")
            }
        } catch {
            expect(false, "\(what): \(error)")
        }
    }

    // MARK: - Colour models

    static func testCMYKJPEGUntouched() {
        print("A CMYK JPEG is never re-encoded")
        let jpeg = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .cmyk)
        expectEqual(FixtureGenerator.jpegComponentCount(jpeg), 4, "fixture JPEG has four components")
        let pdf = FixtureGenerator.imagePDF(jpeg: jpeg, width: 2000, height: 1500, colorSpace: "/DeviceCMYK")
        expectUntouchedAtEveryLevel(pdf, "CMYK")
        do {
            let image = try imageObject(pdf, level: 4)
            expect(image.dict["ColorSpace"] == .name("DeviceCMYK"), "still DeviceCMYK")
            expectEqual(FixtureGenerator.jpegComponentCount(image.data), 4, "still four components")
            let inspection = try PDFSanitizer.inspect(data: pdf)
            expectEqual(inspection.imageCount, 1, "one image")
            expectEqual(inspection.recompressibleImageCount, 0, "not counted as re-encodable")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testGrayJPEGStaysGray() {
        print("A gray JPEG is re-encoded as gray")
        do {
            let jpeg = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .gray)
            let pdf = FixtureGenerator.imagePDF(jpeg: jpeg, width: 2000, height: 1500, colorSpace: "/DeviceGray")
            let image = try imageObject(pdf, level: 2)
            expect(image.data != jpeg, "re-encoded")
            expect(image.dict["ColorSpace"] == .name("DeviceGray"), "declared DeviceGray")
            expectEqual(FixtureGenerator.jpegComponentCount(image.data), 1, "JPEG has one component")
            expect(image.dict["Width"] == .int(1600), "scaled to the 1600 px cap")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testMislabelledJPEGUntouched() {
        print("A JPEG whose component count disagrees with /ColorSpace is left alone")
        let cmyk = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .cmyk)
        let pdf = FixtureGenerator.imagePDF(jpeg: cmyk, width: 2000, height: 1500, colorSpace: "/DeviceRGB")
        expectUntouchedAtEveryLevel(pdf, "CMYK data labelled DeviceRGB")
    }

    static func testCalRGBAndDecodeSkipped() {
        print("Calibrated colour, ICC colour and /Decode arrays are left alone")
        let jpeg = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .rgb)
        let calibrated = FixtureGenerator.imagePDF(
            jpeg: jpeg, width: 2000, height: 1500,
            colorSpace: "[/CalRGB << /WhitePoint [0.9505 1 1.089] >>]"
        )
        expectUntouchedAtEveryLevel(calibrated, "CalRGB")

        let decode = FixtureGenerator.imagePDF(
            jpeg: jpeg, width: 2000, height: 1500,
            colorSpace: "/DeviceRGB", imageExtra: "/Decode [1 0 1 0 1 0]"
        )
        expectUntouchedAtEveryLevel(decode, "/Decode")

        let icc = FixtureGenerator.imagePDF(
            jpeg: jpeg, width: 2000, height: 1500,
            colorSpace: "[/ICCBased 6 0 R]",
            extraObjects: [(6, FixtureGenerator.streamObject(dict: "/N 3", payload: Data("profile".utf8)))]
        )
        expectUntouchedAtEveryLevel(icc, "ICCBased")

        // Dictionary-level rules, including ones that are awkward to build as whole files.
        let base: [String: PDFValue] = [
            "Type": .name("XObject"), "Subtype": .name("Image"), "Width": .int(2000), "Height": .int(1500),
            "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .int(8), "Filter": .name("DCTDecode"),
        ]
        expect(ImageRecompressor.isEligible(dict: base, data: jpeg), "plain RGB JPEG is eligible")
        let variants: [(String, (inout [String: PDFValue]) -> Void)] = [
            ("Flate image", { $0["Filter"] = .name("FlateDecode") }),
            ("filter chain", { $0["Filter"] = .array([.name("FlateDecode"), .name("DCTDecode")]) }),
            ("JPEG 2000", { $0["Filter"] = .name("JPXDecode") }),
            ("CCITT", { $0["Filter"] = .name("CCITTFaxDecode") }),
            ("indirect colour space", { $0["ColorSpace"] = .ref(PDFRef(obj: 9, gen: 0)) }),
            ("Indexed", { $0["ColorSpace"] = .array([.name("Indexed"), .name("DeviceRGB"), .int(255), .string(Data())]) }),
            ("missing colour space", { $0.removeValue(forKey: "ColorSpace") }),
            ("soft mask", { $0["SMask"] = .ref(PDFRef(obj: 9, gen: 0)) }),
            ("colour-key mask", { $0["Mask"] = .array([.int(0), .int(0)]) }),
            ("stencil", { $0["ImageMask"] = .bool(true) }),
            ("16-bit", { $0["BitsPerComponent"] = .int(16) }),
            ("not an image", { $0["Subtype"] = .name("Form") }),
        ]
        for (name, change) in variants {
            var dict = base
            change(&dict)
            expect(!ImageRecompressor.isEligible(dict: dict, data: jpeg), "\(name) is not eligible")
        }
    }

    static func testSMaskTargetSkipped() {
        print("An image used as another image's soft mask is left alone, and so is its owner")
        let picture = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .rgb)
        let mask = FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .gray)
        let pdf = FixtureGenerator.imagePDF(
            jpeg: picture, width: 2000, height: 1500, colorSpace: "/DeviceRGB",
            imageExtra: "/SMask 6 0 R",
            extraObjects: [(6, FixtureGenerator.streamObject(
                dict: "/Type /XObject /Subtype /Image /Width 2000 /Height 1500 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                payload: mask
            ))]
        )
        expectUntouchedAtEveryLevel(pdf, "image with a soft mask", number: 5)
        expectUntouchedAtEveryLevel(pdf, "the soft mask itself", number: 6)
        do {
            let inspection = try PDFSanitizer.inspect(data: pdf)
            expectEqual(inspection.imageCount, 2, "two images")
            expectEqual(inspection.recompressibleImageCount, 0, "neither is re-encodable")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Size

    static func testSmallImageNotDownsampled() {
        print("An image under the cap keeps its dimensions")
        do {
            let jpeg = FixtureGenerator.patternJPEG(width: 800, height: 600, model: .rgb)
            let pdf = FixtureGenerator.imagePDF(jpeg: jpeg, width: 800, height: 600, colorSpace: "/DeviceRGB")
            for level in 2...3 {
                let image = try imageObject(pdf, level: level)
                expect(image.dict["Width"] == .int(800) && image.dict["Height"] == .int(600), "L\(level): still 800×600")
                expect(image.data.count < jpeg.count, "L\(level): re-encoded smaller")
            }
            let maximum = try imageObject(pdf, level: 4)
            expect(maximum.dict["Width"] == .int(800), "L4: 800 px is under the 900 px cap")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLargeImageCappedAtLabel() {
        print("An image over the cap is scaled to exactly the number in the label")
        do {
            let jpeg = FixtureGenerator.patternJPEG(width: 2400, height: 1800, model: .rgb, quality: 0.9)
            let pdf = FixtureGenerator.imagePDF(jpeg: jpeg, width: 2400, height: 1800, colorSpace: "/DeviceRGB")
            for level in 2...4 {
                let profile = CompressionProfiles.profile(for: level)
                guard let cap = profile.maxImageEdge, let quality = profile.jpegQuality else {
                    expect(false, "L\(level) has a cap and a quality")
                    continue
                }
                let image = try imageObject(pdf, level: level)
                expect(image.dict["Width"] == .int(cap), "L\(level): long side is \(cap) px")
                expect(image.dict["Height"] == .int(cap * 3 / 4), "L\(level): aspect ratio kept")
                expect(profile.summary.contains("\(cap) px"), "L\(level) summary states \(cap) px")
                expect(profile.detail.contains("\(cap) px"), "L\(level) detail states \(cap) px")
                let percent = "\(Int((quality * 100).rounded()))"
                expect(profile.summary.contains("quality \(percent)"), "L\(level) summary states quality \(percent)")

                guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    expect(false, "L\(level): output JPEG decodes")
                    continue
                }
                expectEqual(decoded.width, cap, "L\(level): decoded width matches the dictionary")
            }
            expectEqual(ImageRecompressor.targetPixelSize(width: 1800, height: 2400, profile: CompressionProfiles.profile(for: 2)).1, 1600, "portrait: the long side is the height")
            expect(ImageRecompressor.targetPixelSize(width: 1600, height: 1200, profile: CompressionProfiles.profile(for: 2)) == (1600, 1200), "exactly at the cap: unchanged")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Labels

    static func testNoDpiInLabels() {
        print("No label claims a dpi figure")
        var strings = [CompressionProfiles.eligibilityNote]
        for profile in CompressionProfiles.all {
            strings += [profile.name, profile.summary, profile.detail]
        }
        for text in strings {
            expect(!text.lowercased().contains("dpi"), "no dpi in \"\(text.prefix(40))…\"")
        }
        let readme = (try? String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        expect(!readme.lowercased().contains("dpi"), "no dpi in the README")

        let maximum = CompressionProfiles.profile(for: 4)
        for profile in CompressionProfiles.all {
            expectEqual(profile.detail.contains("grayscale"), profile.convertNearGrayToGray, "\(profile.name): grayscale conversion is mentioned exactly when it happens")
        }
        expect(maximum.convertNearGrayToGray, "Maximum converts near-gray photos")
        let light = CompressionProfiles.profile(for: 1)
        expect(light.detail.contains("often changes nothing"), "Light says it often changes nothing")
        for word in ["CMYK", "masked", "non-JPEG", "text"] {
            expect(CompressionProfiles.eligibilityNote.contains(word), "eligibility note mentions \(word)")
        }
    }

    static func testReadmeCompressionTableMatchesProfiles() {
        print("README compression table uses the profile strings")
        let readme = (try? String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        for profile in CompressionProfiles.all {
            expect(readme.contains("| **\(profile.name)** | \(profile.detail) |"), "README row for \(profile.name)")
        }
        expect(readme.contains(CompressionProfiles.eligibilityNote), "README carries the eligibility note")
    }

    // MARK: - Counts and report

    static func testEligibilityCountMatchesExport() {
        print("The image count shown in review matches what the save does")
        do {
            let photo = FixtureGenerator.photoPDF
            let inspection = try PDFSanitizer.inspect(data: photo)
            expectEqual(inspection.imageCount, 1, "photo: one image")
            expectEqual(inspection.recompressibleImageCount, 1, "photo: one re-encodable")
            let summary = ReviewSummary(inspection)
            expectEqual(summary.compressionScopeNote(for: CompressionProfiles.profile(for: 2)), "1 of 1 image in this PDF can be re-encoded.", "scope note")
            expect(summary.compressionScopeNote(for: CompressionProfiles.profile(for: 1)) == nil, "no scope note for a lossless level")

            for level in 2...4 {
                let report = try PDFSanitizer.sanitizeWithReport(
                    data: photo, options: .default, compression: CompressionProfiles.profile(for: level)
                ).report
                expectEqual(report.imagesRecompressed, inspection.recompressibleImageCount, "L\(level): images re-encoded")
                expect(report.message.contains("re-encoded 1 of 1 image"), "L\(level): message says so")
            }

            let cmyk = FixtureGenerator.imagePDF(
                jpeg: FixtureGenerator.patternJPEG(width: 2000, height: 1500, model: .cmyk),
                width: 2000, height: 1500, colorSpace: "/DeviceCMYK"
            )
            let cmykSummary = ReviewSummary(try PDFSanitizer.inspect(data: cmyk))
            expect(cmykSummary.compressionScopeNote(for: CompressionProfiles.profile(for: 3))?.contains("None of the 1 image") == true, "CMYK scope note says none can be re-encoded")
            let cmykReport = try PDFSanitizer.sanitizeWithReport(
                data: cmyk, options: .default, compression: CompressionProfiles.profile(for: 3)
            ).report
            expectEqual(cmykReport.imagesRecompressed, 0, "CMYK: nothing re-encoded")

            let textOnly = ReviewSummary(try PDFSanitizer.inspect(data: try loadFixture("multipage_shared_resources.pdf")))
            expect(textOnly.compressionScopeNote(for: CompressionProfiles.profile(for: 2))?.contains("no images") == true, "text file scope note")

            // Light on a file with an uncompressed content stream.
            let light = try PDFSanitizer.sanitizeWithReport(
                data: try loadFixture("multipage_50.pdf"), options: .default,
                compression: CompressionProfiles.profile(for: 1)
            ).report
            expectEqual(light.imagesRecompressed, 0, "Light never re-encodes images")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testRecompressedJPEGHasNoMetadata() {
        print("A re-encoded JPEG carries no Exif or Photoshop block")
        do {
            for level in 2...4 {
                let result = try PDFSanitizer.sanitizeWithReport(
                    data: FixtureGenerator.photoPDF, options: .default,
                    compression: CompressionProfiles.profile(for: level)
                )
                guard let jpeg = try firstJPEGPayload(from: result.data) else {
                    expect(false, "L\(level): image present")
                    continue
                }
                expect(!containsExifMarker(jpeg), "L\(level): no Exif")
                expect(!contains(jpeg, "Photoshop 3.0"), "L\(level): no Photoshop block")
                expect(result.report.leftBehind.isEmpty, "L\(level): report has nothing left behind")
                expectEqual(try PDFSanitizer.inspect(data: result.data).jpegWithAppMetadataCount, 0, "L\(level): re-inspection finds no JPEG metadata")
            }
        } catch {
            expect(false, "\(error)")
        }
    }
}
