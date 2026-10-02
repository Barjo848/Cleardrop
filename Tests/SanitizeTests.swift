import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension CleardropTests {
    // MARK: - Refusals

    static func testErrorMessagesAreShort() {
        print("Errors")
        expectEqual(PDFSanitizerError.signed.errorDescription, "Signed PDFs are not modified.", "sig")
    }

    static func testRejectsEncryptedSanitize() {
        print("Encrypted")
        do {
            _ = try PDFSanitizer.sanitize(data: try loadFixture("encrypted_user.pdf"), options: .default)
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            expect(e == .encrypted, "encrypted")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testRejectsSignedSanitize() {
        print("Signed")
        do {
            _ = try PDFSanitizer.sanitize(data: try loadFixture("signed_preview.pdf"), options: .default)
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            expect(e == .signed, "signed")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Document level

    static func testStripsPlantedInfoAuthor() {
        print("Document level: Info author")
        do {
            let data = try loadFixture("info_author.pdf")
            expect(contains(data, plantedAuthor), "source")
            let out = try PDFSanitizer.sanitize(data: data, options: .documentLevelOnly)
            expect(!contains(out, plantedAuthor), "gone")
            expect(!contains(out, plantedTitle), "title gone")
            expect(!contains(out, plantedCreator), "creator gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testStripsCatalogXMPDocumentLevel() {
        print("Document level: Catalog XMP")
        do {
            let data = try loadFixture("xmp_catalog.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .documentLevelOnly)
            expect(!contains(out, plantedXmpDocID), "xmp gone")
            expect(!contains(out, plantedPiece), "piece gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testDocumentLevelDoesNotRequirePageMetadataGone() {
        print("Document level: does not strip page Metadata (control)")
        do {
            let data = try loadFixture("page_metadata.pdf")
            expect(contains(data, plantedPageXMP), "source page xmp")
            let out = try PDFSanitizer.sanitize(data: data, options: .documentLevelOnly)
            // documentLevelOnly leaves page-level Metadata
            expect(contains(out, plantedPageXMP), "page xmp still present under documentLevelOnly")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testRegeneratesTrailerID() {
        print("Document level: /ID")
        do {
            let data = try loadFixture("trailer_id.pdf")
            expect(contains(data, knownID_A), "source id")
            let out = try PDFSanitizer.sanitize(data: data, options: .documentLevelOnly)
            expect(!contains(out, knownID_A), "id regenerated")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testNoQuartzProducerInjected() {
        print("No Quartz")
        do {
            let out = try PDFSanitizer.sanitize(
                data: try loadFixture("minimal_empty.pdf"),
                options: .default
            )
            expect(!contains(out, "Quartz PDFContext"), "no quartz")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testOutputUsesCleanName() {
        print("Clean name")
        do {
            let url = try writeTemp(named: "n.pdf", data: try loadFixture("minimal_empty.pdf"))
            defer { try? FileManager.default.removeItem(at: url) }
            let name = ExportNaming.suggestedFileName(
                original: url,
                profile: CompressionProfiles.profile(for: 0)
            )
            expect(name.hasSuffix("-clean.pdf"), "suggested name ends in -clean.pdf (got \(name))")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: out) }
            try PDFSanitizer.process(from: url, to: out, options: .default)
            expect(FileManager.default.fileExists(atPath: out.path), "written under the suggested name")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testSourceUnchangedAfterStrip() {
        print("Source immutable")
        do {
            let data = try loadFixture("info_author.pdf")
            let url = try writeTemp(named: "s.pdf", data: data)
            defer { try? FileManager.default.removeItem(at: url) }
            let before = sha256(data)
            let out = tempURL(named: "s-clean.pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try PDFSanitizer.process(from: url, to: out, options: .default)
            expect(sha256(try Data(contentsOf: url)) == before, "stable")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Per-object strip

    static func testEmbeddedJPEGEXIFRemoved() {
        print("JPEG EXIF removed")
        do {
            let data = try loadFixture("embedded_jpeg_exif.pdf")
            expect(contains(data, plantedJPEGExif), "source exif token")
            expect(containsExifMarker(data), "source Exif\\0\\0")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedJPEGExif), "exif token gone")
            expect(!containsExifMarker(out), "Exif marker gone")
            // Stream still present
            let jpeg = try firstJPEGPayload(from: out)
            expect(jpeg != nil, "DCT stream remains")
            if let jpeg {
                expect(jpeg.starts(with: Data([0xFF, 0xD8])), "still JPEG SOI")
                expect(!containsExifMarker(jpeg), "stream has no Exif")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testEmbeddedJPEGXMPRemoved() {
        print("JPEG XMP removed")
        do {
            let data = try loadFixture("embedded_jpeg_exif.pdf")
            expect(contains(data, plantedJPEGXMP), "source xmp token")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedJPEGXMP), "xmp token gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testJPEGStillDecodableAfterScrub() {
        print("JPEG decodable after scrub")
        do {
            let out = try PDFSanitizer.sanitize(
                data: try loadFixture("embedded_jpeg_exif.pdf"),
                options: .default
            )
            guard let jpeg = try firstJPEGPayload(from: out) else {
                expect(false, "no jpeg payload")
                return
            }
            // ImageIO decode
            guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
                expect(false, "CGImageSource create")
                return
            }
            let count = CGImageSourceGetCount(src)
            expect(count >= 1, "image count \(count)")
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            expect(img != nil, "decoded CGImage")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testAnnotationAuthorStripped() {
        print("Annot author stripped")
        do {
            let data = try loadFixture("annot_author.pdf")
            expect(contains(data, plantedAnnotAuthor), "source author")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedAnnotAuthor), "author gone")
            // Annot object should still exist (Subtype FreeText)
            expect(contains(out, "FreeText"), "annot remains")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testAnnotationDatesStripped() {
        print("Annot dates stripped")
        do {
            let data = try loadFixture("annot_author.pdf")
            expect(contains(data, plantedAnnotDate), "source date")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedAnnotDate), "date gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testAnnotationContentsPreserved() {
        print("Annot contents preserved")
        do {
            let out = try PDFSanitizer.sanitize(
                data: try loadFixture("annot_author.pdf"),
                options: .default
            )
            expect(contains(out, "Visible note text stays"), "contents kept")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testPageLevelMetadataRemoved() {
        print("Page Metadata removed")
        do {
            let data = try loadFixture("page_metadata.pdf")
            expect(contains(data, plantedPageXMP), "source")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedPageXMP), "page xmp gone")
            let g = try PDFParser.parse(out)
            expect(!PDFGraphInspect.hasAnyMetadataKey(g), "no Metadata keys")
            expect(!PDFGraphInspect.hasMetadataOutsideCatalog(g), "no non-catalog Metadata")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testPageCountStillPreservedDeep() {
        print("PageCount deep")
        do {
            for name in ["page_metadata.pdf", "annot_author.pdf", "embedded_jpeg_exif.pdf", "multipage_shared_resources.pdf"] {
                let data = try loadFixture(name)
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                expectEqual(pdfKitPageCount(data), pdfKitPageCount(out), "\(name) pageCount")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testDocumentLevelStillHoldsUnderDeep() {
        print("Document level: holds under deep default")
        do {
            let data = try loadFixture("info_author.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedAuthor), "author")
            expect(!contains(out, plantedProducer), "producer")
            let g = try PDFParser.parse(out)
            expect(!PDFGraphInspect.hasInfoDict(g), "no Info")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testDefaultEnablesDeepFlags() {
        print("Default options enable per-object strip")
        let d = SanitizeOptions.default
        expect(d.stripAnnotationIdentity, "annot")
        expect(d.stripEmbeddedImageMetadata, "jpeg")
        expect(d.stripAllObjectMetadataStreams, "all meta")
        expect(!SanitizeOptions.documentLevelOnly.stripAllObjectMetadataStreams, "doc-only off")
    }

    static func testInspectResidualFlagsOnPageMetadata() {
        print("inspect residual flags")
        do {
            let data = try loadFixture("page_metadata.pdf")
            let info = try PDFSanitizer.inspect(data: data)
            expect(info.hasOtherMetadataStreams, "page Metadata flagged")
            expect(info.pageCount == 1, "pageCount")
            // After strip, re-inspect cleaned bytes
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let after = try PDFSanitizer.inspect(data: out)
            expect(!after.hasOtherMetadataStreams, "cleaned has no other Metadata")
            expect(!after.hasCatalogXMP, "no catalog xmp")
            expect(!after.hasInfoDict, "no info")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testScrubJPEGUnit() {
        print("JPEG scrubber unit")
        // Build tiny SOI + APP1 + EOI
        var jpeg = Data([0xFF, 0xD8])
        let payload = Data("Exif\0\0PLANTED_UNIT".utf8)
        let len = 2 + payload.count
        jpeg.append(0xFF)
        jpeg.append(0xE1)
        jpeg.append(UInt8((len >> 8) & 0xFF))
        jpeg.append(UInt8(len & 0xFF))
        jpeg.append(payload)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        expect(contains(jpeg, "PLANTED_UNIT"), "before")
        let scrubbed = ImageMetadataStripper.scrubJPEGIfNeeded(jpeg)
        expect(!contains(scrubbed, "PLANTED_UNIT"), "after")
        expect(scrubbed.starts(with: Data([0xFF, 0xD8])), "SOI")
        expect(scrubbed.suffix(2) == Data([0xFF, 0xD9]) || scrubbed.contains(Data([0xFF, 0xD9])), "has EOI")
    }
}
