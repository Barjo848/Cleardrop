import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension CleardropTests {
    // MARK: - Fidelity tests

    static func testFidelityContentStreamsByteIdentical() {
        print("Fidelity: content stream bytes identical after strip")
        // Fixtures without JPEG scrub on content streams
        for name in ["minimal_empty.pdf", "info_author.pdf", "multipage_shared_resources.pdf", "page_metadata.pdf"] {
            do {
                let data = try loadFixture(name)
                let before = try PDFParser.parse(data)
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                let after = try PDFParser.parse(out)
                let b = contentOnlyPayloads(before)
                let a = contentOnlyPayloads(after)
                // Same object numbers for content streams
                for (num, payload) in b {
                    guard let ap = a[num] else {
                        expect(false, "\(name): missing stream obj \(num)")
                        continue
                    }
                    expect(ap == payload, "\(name): stream \(num) bytes identical (len \(payload.count))")
                }
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testFidelitySharedFontAndPageCount() {
        print("Fidelity: shared font + pageCount")
        do {
            let data = try loadFixture("multipage_shared_resources.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let g0 = try PDFParser.parse(data)
            let g1 = try PDFParser.parse(out)
            expectEqual(PDFGraphInspect.pageCount(g0), PDFGraphInspect.pageCount(g1), "pageCount")
            expect(g0.objects[5] != nil && g1.objects[5] != nil, "font obj 5 both")
            // Font dict Type preserved
            if case .dict(let d0) = g0.objects[5]?.value,
               case .dict(let d1) = g1.objects[5]?.value,
               case .name(let t0) = d0["Type"], case .name(let t1) = d1["Type"]
            {
                expectEqual(t0, t1, "font Type")
                if case .name(let b0) = d0["BaseFont"], case .name(let b1) = d1["BaseFont"] {
                    expectEqual(b0, b1, "BaseFont")
                }
            } else {
                expect(false, "font dicts")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityRenderedPagesPixelExact() {
        print("Fidelity: PDFKit rendered pages pixel-exact (no JPEG fixtures)")
        for name in ["minimal_empty.pdf", "info_author.pdf", "multipage_shared_resources.pdf", "annot_author.pdf"] {
            do {
                let data = try loadFixture(name)
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                let pc = pdfKitPageCount(data) ?? 0
                expect(pc > 0, "\(name) opens")
                for i in 0..<pc {
                    guard let rb = renderPageBitmap(data, pageIndex: i),
                          let ra = renderPageBitmap(out, pageIndex: i)
                    else {
                        expect(false, "\(name) p\(i) render failed")
                        continue
                    }
                    let delta = maxChannelDelta(rb, ra)
                    expect(delta == 0, "\(name) p\(i) max channel delta \(delta) (want 0)")
                }
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testFidelityRichFixtureFullStrip() {
        print("Fidelity: rich fixture strip + render + content streams")
        do {
            let data = try loadFixture("fidelity_rich.pdf")
            expect(contains(data, plantedAuthor), "has author before")
            let before = try PDFParser.parse(data)
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedAuthor), "author gone")
            expect(!contains(out, "PLANTED_XMP_FIDELITY"), "xmp gone")
            expect(!contains(out, plantedAnnotAuthor), "annot author gone")
            expect(contains(out, "Visible note"), "annot contents kept")
            expect(contains(out, "Fidelity Page 1"), "page text kept")
            expect(contains(out, "Fidelity Page 2"), "page2 text kept")

            let after = try PDFParser.parse(out)
            expectEqual(PDFGraphInspect.pageCount(before), 2, "2 pages in")
            expectEqual(PDFGraphInspect.pageCount(after), 2, "2 pages out")

            // Non-image content streams byte-identical (objs 5, 6)
            for num in [5, 6] {
                if case .stream(_, let b) = before.objects[num]?.value,
                   case .stream(_, let a) = after.objects[num]?.value
                {
                    expect(a == b, "content stream \(num) identical")
                } else {
                    expect(false, "content stream \(num) missing")
                }
            }
            // Font shared
            expect(after.objects[7] != nil, "font 7 present")

            // Render both pages
            for i in 0..<2 {
                guard let rb = renderPageBitmap(data, pageIndex: i, scale: 2),
                      let ra = renderPageBitmap(out, pageIndex: i, scale: 2)
                else {
                    expect(false, "render p\(i)")
                    continue
                }
                let delta = maxChannelDelta(rb, ra)
                // JPEG EXIF scrub should not change decoded pixels; allow 0 only
                expect(delta == 0, "rich p\(i) pixel delta \(delta)")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityJPEGPixelsUnchangedAfterEXIFScrub() {
        print("Fidelity: JPEG decoded pixels unchanged after EXIF scrub")
        do {
            let data = try loadFixture("embedded_jpeg_exif.pdf")
            let before = try PDFParser.parse(data)
            var jpegBefore: Data?
            for (_, e) in before.objects {
                if case .stream(let d, let payload) = e.value, ImageMetadataStripper.isDCTDecode(d) {
                    jpegBefore = payload
                    break
                }
            }
            guard let jpegBefore else {
                expect(false, "no jpeg before")
                return
            }
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let after = try PDFParser.parse(out)
            var jpegAfter: Data?
            for (_, e) in after.objects {
                if case .stream(let d, let payload) = e.value, ImageMetadataStripper.isDCTDecode(d) {
                    jpegAfter = payload
                    break
                }
            }
            guard let jpegAfter else {
                expect(false, "no jpeg after")
                return
            }
            expect(jpegBefore != jpegAfter, "container bytes changed (APP removed)")
            expect(!containsExifMarker(jpegAfter), "no Exif after")
            guard let pb = decodeJPEGPixels(jpegBefore),
                  let pa = decodeJPEGPixels(jpegAfter)
            else {
                expect(false, "decode failed")
                return
            }
            expectEqual(pb.0, pa.0, "width")
            expectEqual(pb.1, pa.1, "height")
            expect(pb.2 == pa.2, "pixel buffer identical")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityAnnotContentsAndGeometryPreserved() {
        print("Fidelity: annotation Contents + Rect preserved")
        do {
            let data = try loadFixture("annot_author.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let g0 = try PDFParser.parse(data)
            let g1 = try PDFParser.parse(out)
            // Find FreeText annot
            func freeText(_ g: PDFDocumentGraph) -> [String: PDFValue]? {
                for (_, e) in g.objects {
                    guard let d = PDFGraphInspect.dict(of: e.value) else { continue }
                    if case .name(let s) = d["Subtype"], s == "FreeText" { return d }
                }
                return nil
            }
            guard let a0 = freeText(g0), let a1 = freeText(g1) else {
                expect(false, "annot missing")
                return
            }
            expectEqual(
                PDFGraphInspect.stringValue(a0["Contents"]),
                PDFGraphInspect.stringValue(a1["Contents"]),
                "Contents"
            )
            // Rect array equality via description of values
            if case .array(let r0) = a0["Rect"], case .array(let r1) = a1["Rect"] {
                expectEqual(r0.count, r1.count, "Rect count")
                for i in 0..<r0.count {
                    expectEqual(
                        PDFGraphInspect.stringValue(r0[i]),
                        PDFGraphInspect.stringValue(r1[i]),
                        "Rect[\(i)]"
                    )
                }
            } else {
                expect(false, "Rect arrays")
            }
            expect(a1["T"] == nil, "author T stripped")
            expect(a1["M"] == nil, "date M stripped")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityMediaBoxesPreserved() {
        print("Fidelity: MediaBox preserved")
        do {
            let data = try loadFixture("fidelity_rich.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let g0 = try PDFParser.parse(data)
            let g1 = try PDFParser.parse(out)
            for pageObj in [3, 4] {
                guard let d0 = PDFGraphInspect.dict(of: g0.objects[pageObj]!.value),
                      let d1 = PDFGraphInspect.dict(of: g1.objects[pageObj]!.value),
                      case .array(let b0) = d0["MediaBox"],
                      case .array(let b1) = d1["MediaBox"]
                else {
                    expect(false, "MediaBox page \(pageObj)")
                    continue
                }
                expectEqual(b0.count, 4, "box len")
                for i in 0..<4 {
                    expectEqual(
                        PDFGraphInspect.stringValue(b0[i]),
                        PDFGraphInspect.stringValue(b1[i]),
                        "MediaBox[\(i)] p\(pageObj)"
                    )
                }
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityIdentityRewriteThenStrip() {
        print("Fidelity: identity rewrite then full strip still pixel-exact")
        do {
            let data = try loadFixture("multipage_shared_resources.pdf")
            let mid = try PDFSanitizer.sanitize(data: data, options: .identityRewriteOnly)
            let out = try PDFSanitizer.sanitize(data: mid, options: .default)
            for i in 0..<(pdfKitPageCount(data) ?? 0) {
                guard let rb = renderPageBitmap(data, pageIndex: i),
                      let ra = renderPageBitmap(out, pageIndex: i)
                else {
                    expect(false, "render")
                    continue
                }
                expect(maxChannelDelta(rb, ra) == 0, "pixel exact p\(i)")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFidelityMultipage50RenderSample() {
        print("Fidelity: multipage_50 render sample pages")
        do {
            let data = try loadFixture("multipage_50.pdf")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expectEqual(pdfKitPageCount(data), 50, "50 in")
            expectEqual(pdfKitPageCount(out), 50, "50 out")
            // Sample first, middle, last
            for i in [0, 24, 49] {
                guard let rb = renderPageBitmap(data, pageIndex: i, scale: 1.5),
                      let ra = renderPageBitmap(out, pageIndex: i, scale: 1.5)
                else {
                    expect(false, "render p\(i)")
                    continue
                }
                let d = maxChannelDelta(rb, ra)
                expect(d == 0, "p\(i) delta \(d)")
            }
            // Content stream objs for page 1 text still present
            expect(contains(out, "Page 1"), "text Page 1")
            expect(contains(out, "Page 50"), "text Page 50")
        } catch {
            expect(false, "\(error)")
        }
    }
}
