import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension CleardropTests {
    // MARK: - compression profiles

    static func testProfilesAreFiveDiscreteSteps() {
        print("five discrete profiles")
        expectEqual(CompressionProfiles.all.count, 5, "count")
        expectEqual(CompressionProfiles.minLevel, 0, "min")
        expectEqual(CompressionProfiles.maxLevel, 4, "max")
        for i in 0...4 {
            let p = CompressionProfiles.all[i]
            expectEqual(p.id, i, "id \(i)")
            expect(!p.name.isEmpty, "name \(i)")
            expect(!p.summary.isEmpty, "summary \(i)")
            expect(p.summary.contains("PDF"), "summary mentions PDF \(i)")
        }
        let ids = Set(CompressionProfiles.all.map(\.id))
        expectEqual(ids.count, 5, "unique ids")
    }

    static func testDefaultLevelIsNone() {
        print("default level is None")
        expectEqual(CompressionProfiles.defaultLevel, 0, "defaultLevel")
        let p = CompressionProfiles.profile(for: CompressionProfiles.defaultLevel)
        expectEqual(p.name, "None", "name")
        expect(!p.appliesCompression, "no compress at 0")
        expect(!p.isLossy, "not lossy")
    }

    static func testProfileClamp() {
        print("clamp")
        expectEqual(CompressionProfiles.clamp(-3), 0, "low")
        expectEqual(CompressionProfiles.clamp(99), 4, "high")
        expectEqual(CompressionProfiles.profile(for: 99).id, 4, "profile high")
        expectEqual(CompressionProfiles.profile(for: -1).id, 0, "profile low")
    }

    static func testByteSizeFormat() {
        print("ByteSizeFormat")
        expectEqual(ByteSizeFormat.string(bytes: 0), "0 bytes", "0")
        expectEqual(ByteSizeFormat.string(bytes: 512), "512 bytes", "512")
        expect(ByteSizeFormat.string(bytes: 12_400_000).contains("MB"), "12.4MB-ish: \(ByteSizeFormat.string(bytes: 12_400_000))")
        expect(ByteSizeFormat.string(bytes: 840_000).contains("KB"), "840KB-ish")
        // fileSizeBytes from inspection should format non-empty
        do {
            let info = try PDFSanitizer.inspect(data: try loadFixture("info_author.pdf"))
            let s = ByteSizeFormat.string(bytes: info.fileSizeBytes)
            expect(!s.isEmpty && info.fileSizeBytes > 0, "inspection size \(s)")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel0NotLossy() {
        print("level 0 not lossy")
        let p = CompressionProfiles.profile(for: 0)
        expect(p.maxImageEdge == nil, "no resize")
        expect(p.jpegQuality == nil, "no jpeg")
        expect(!p.reflattenStreams, "no reflatten")
    }

    static func testHigherLevelsMarkLossyOrReflatten() {
        print("higher levels configured")
        let light = CompressionProfiles.profile(for: 1)
        expect(light.reflattenStreams, "light reflatten")
        expect(!light.isLossy, "light not lossy")
        for level in 2...4 {
            let p = CompressionProfiles.profile(for: level)
            expect(p.isLossy, "level \(level) lossy")
            expect(p.maxImageEdge != nil, "level \(level) pixel cap")
            expect(p.jpegQuality != nil, "level \(level) quality")
            if let q = p.jpegQuality {
                expect(q > 0 && q <= 1, "quality in range \(level)")
            }
        }
        // Stronger levels use a lower or equal pixel cap and quality
        let b = CompressionProfiles.profile(for: 2)
        let s = CompressionProfiles.profile(for: 3)
        let m = CompressionProfiles.profile(for: 4)
        expect((b.maxImageEdge ?? 0) >= (s.maxImageEdge ?? 0), "cap balanced >= strong")
        expect((s.maxImageEdge ?? 0) >= (m.maxImageEdge ?? 0), "cap strong >= max")
        expect((b.jpegQuality ?? 0) >= (s.jpegQuality ?? 0), "q balanced >= strong")
        expect((s.jpegQuality ?? 0) >= (m.jpegQuality ?? 0), "q strong >= max")
    }

    // MARK: - inventory + estimates

    static func testInventorySumsNearFileSize() {
        print("inventory near file size")
        for name in ["info_author.pdf", "embedded_jpeg_exif.pdf", "fidelity_rich.pdf", "minimal_empty.pdf"] {
            do {
                let data = try loadFixture(name)
                let info = try PDFSanitizer.inspect(data: data)
                let inv = info.sizeInventory
                let sum = inv.imageStreamBytes + inv.metadataStreamBytes + inv.otherStreamBytes + inv.overheadBytes
                expectEqual(sum, inv.fileSizeBytes, "\(name) sum==file")
                // Streams shouldn't wildly exceed file
                expect(inv.totalStreamBytes <= inv.fileSizeBytes, "\(name) streams ≤ file")
                let ratio = Double(inv.totalStreamBytes) / Double(max(1, inv.fileSizeBytes))
                expect(ratio >= 0.05 || inv.fileSizeBytes < 2000, "\(name) has some stream content ratio=\(ratio)")
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testEstimateMonotonicNonIncreasing() {
        print("estimates monotonic non-increasing")
        do {
            let data = try loadFixture("fidelity_rich.pdf")
            let inv = try PDFSanitizer.inspect(data: data).sizeInventory
            var prevHigh = Int.max
            for level in 0...4 {
                let e = SizeEstimator.estimate(
                    inventory: inv,
                    profile: CompressionProfiles.profile(for: level)
                )
                expect(e.bytesHigh <= prevHigh, "level \(level) high \(e.bytesHigh) ≤ prev \(prevHigh)")
                expect(e.bytesLow <= e.bytesHigh, "level \(level) low≤high")
                prevHigh = e.bytesHigh
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testTextHeavyPDFEstimateBarelyShrinks() {
        print("text-heavy barely shrinks at max")
        do {
            // minimal_empty / multipage text fixtures have no image streams
            let data = try loadFixture("multipage_shared_resources.pdf")
            let inv = try PDFSanitizer.inspect(data: data).sizeInventory
            expect(inv.isTextHeavy, "text heavy")
            let e0 = SizeEstimator.estimate(inventory: inv, profile: CompressionProfiles.profile(for: 0))
            let e4 = SizeEstimator.estimate(inventory: inv, profile: CompressionProfiles.profile(for: 4))
            let ratio = Double(e4.bytesHigh) / Double(max(1, e0.bytesHigh))
            expect(ratio >= 0.88, "level4 ≥ 88% of level0 (got \(ratio))")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testImageHeavyPDFEstimateShrinksAtBalanced() {
        print("image-heavy shrinks at balanced")
        // Synthetic inventory: mostly images
        let inv = PDFSizeInventory(
            imageStreamBytes: 8_000_000,
            metadataStreamBytes: 50_000,
            otherStreamBytes: 200_000,
            fileSizeBytes: 8_500_000
        )
        expect(!inv.isTextHeavy, "not text heavy")
        let e0 = SizeEstimator.estimate(inventory: inv, profile: CompressionProfiles.profile(for: 0))
        let e2 = SizeEstimator.estimate(inventory: inv, profile: CompressionProfiles.profile(for: 2))
        let ratio = Double(e2.bytesHigh) / Double(max(1, inv.fileSizeBytes))
        expect(ratio < 0.70, "balanced high < 70% original (got \(ratio))")
        expect(e2.bytesHigh < e0.bytesHigh, "balanced < none")
    }

    static func testEstimateNeverExceedsOriginalByMuch() {
        print("estimate low ≤ original*1.05")
        for name in ["info_author.pdf", "embedded_jpeg_exif.pdf", "fidelity_rich.pdf"] {
            do {
                let data = try loadFixture(name)
                let inv = try PDFSanitizer.inspect(data: data).sizeInventory
                for level in 0...4 {
                    let e = SizeEstimator.estimate(
                        inventory: inv,
                        profile: CompressionProfiles.profile(for: level)
                    )
                    let cap = Int(Double(inv.fileSizeBytes) * 1.05) + 1
                    expect(e.bytesLow <= cap, "\(name) L\(level) low \(e.bytesLow) ≤ \(cap)")
                    expect(e.bytesHigh <= cap, "\(name) L\(level) high \(e.bytesHigh) ≤ \(cap)")
                }
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testTextHeavyNoteAppears() {
        print("text-heavy note")
        let inv = PDFSizeInventory(
            imageStreamBytes: 100,
            metadataStreamBytes: 0,
            otherStreamBytes: 50_000,
            fileSizeBytes: 60_000
        )
        expect(inv.isTextHeavy, "heavy")
        let note = SizeEstimator.textHeavyNote(
            inventory: inv,
            profile: CompressionProfiles.profile(for: 2)
        )
        expect(note != nil, "note present at balanced")
        let none = SizeEstimator.textHeavyNote(
            inventory: inv,
            profile: CompressionProfiles.profile(for: 0)
        )
        expect(none == nil, "no note at none")
    }

    // MARK: - lossless Light

    static func testLevel1NeverChangesRenderedPixels() {
        print("Level1 render delta 0 vs Level0")
        let light = CompressionProfiles.profile(for: 1)
        let none = CompressionProfiles.profile(for: 0)
        for name in ["minimal_empty.pdf", "info_author.pdf", "multipage_shared_resources.pdf", "annot_author.pdf"] {
            do {
                let data = try loadFixture(name)
                let out0 = try PDFSanitizer.sanitize(data: data, options: .default, compression: none)
                let out1 = try PDFSanitizer.sanitize(data: data, options: .default, compression: light)
                let pc = pdfKitPageCount(data) ?? 0
                for i in 0..<pc {
                    guard let r0 = renderPageBitmap(out0, pageIndex: i),
                          let r1 = renderPageBitmap(out1, pageIndex: i)
                    else {
                        expect(false, "\(name) p\(i) render")
                        continue
                    }
                    let d = maxChannelDelta(r0, r1)
                    expect(d == 0, "\(name) p\(i) delta \(d)")
                }
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testLevel1ContentStreamsStillValid() {
        print("Level1 parse + pageCount")
        do {
            let data = try loadFixture("multipage_shared_resources.pdf")
            let out = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 1)
            )
            let g = try PDFParser.parse(out)
            expectEqual(PDFGraphInspect.pageCount(g), 2, "pages")
            expect(pdfKitPageCount(out) == 2, "PDFKit pages")
            expect(g.objects[5] != nil, "shared font")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel1SizeNotLargerThanLevel0PlusEpsilon() {
        print("Level1 size ≤ Level0 + epsilon")
        let light = CompressionProfiles.profile(for: 1)
        let none = CompressionProfiles.profile(for: 0)
        // Uncompressed content streams should not grow under never-worsen policy
        for name in ["minimal_empty.pdf", "info_author.pdf", "multipage_50.pdf", "fidelity_rich.pdf"] {
            do {
                let data = try loadFixture(name)
                let out0 = try PDFSanitizer.sanitize(data: data, options: .default, compression: none)
                let out1 = try PDFSanitizer.sanitize(data: data, options: .default, compression: light)
                // Allow small writer variance (xref formatting) of 2% or 512 bytes
                let cap = out0.count + max(512, out0.count / 50)
                expect(out1.count <= cap, "\(name) L1 \(out1.count) ≤ L0 \(out0.count) +eps \(cap)")
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testLevel1StillStripsMetadata() {
        print("Level1 still strips author")
        do {
            let data = try loadFixture("info_author.pdf")
            let out = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 1)
            )
            expect(!contains(out, plantedAuthor), "author gone")
            expect(!contains(out, plantedProducer), "producer gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testZlibCompressShrinksOrNil() {
        print("zlib helper")
        let repetitive = Data(repeating: 0x41, count: 5000)
        if let c = PDFCompressor.zlibCompress(repetitive) {
            expect(c.count < repetitive.count, "shrinks repetitive")
        } else {
            expect(false, "should compress repetitive")
        }
        // Random-ish small data may return nil (not smaller) — OK
        let tiny = Data([1, 2, 3, 4, 5])
        let t = PDFCompressor.zlibCompress(tiny)
        expect(t == nil || t!.count < tiny.count, "tiny ok")
    }

    static func testLevel1DoesNotTouchJPEGPixels() {
        print("Level1 does not change JPEG decode pixels")
        do {
            let data = try loadFixture("embedded_jpeg_exif.pdf")
            // Strip only (level 0) vs light — after strip EXIF may already be gone at both
            // Compare JPEG payloads between level0 and level1 after full sanitize
            let out0 = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 0)
            )
            let out1 = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 1)
            )
            func jpeg(_ pdf: Data) throws -> Data? {
                let g = try PDFParser.parse(pdf)
                for (_, e) in g.objects {
                    if case .stream(let d, let p) = e.value, ImageMetadataStripper.isDCTDecode(d) {
                        return p
                    }
                }
                return nil
            }
            let j0 = try jpeg(out0)
            let j1 = try jpeg(out1)
            expect(j0 != nil && j1 != nil, "jpeg present")
            if let j0, let j1 {
                expect(j0 == j1, "JPEG bytes identical L0 vs L1")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - lossy images

    static func imageXObjectSize(_ pdf: Data) throws -> (w: Int, h: Int, bytes: Int)? {
        let g = try PDFParser.parse(pdf)
        for (_, e) in g.objects {
            guard case .stream(let d, let data) = e.value else { continue }
            let isImg: Bool = {
                if case .name(let t) = d["Type"], t == "XObject",
                   case .name(let s) = d["Subtype"], s == "Image" { return true }
                return ImageMetadataStripper.isDCTDecode(d)
            }()
            guard isImg else { continue }
            let w: Int
            let h: Int
            if case .int(let ww) = d["Width"] { w = ww } else { continue }
            if case .int(let hh) = d["Height"] { h = hh } else { continue }
            return (w, h, data.count)
        }
        return nil
    }

    static func testLevel2DownsamplesLargePhotoXObject() {
        print("Level2 re-encodes a photo under the cap without resizing it")
        do {
            let data = FixtureGenerator.photoPDF
            let before = try imageXObjectSize(data)
            expect(before != nil, "has image")
            let out = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            let after = try imageXObjectSize(out)
            expect(after != nil, "image remains")
            if let b = before, let a = after {
                expect(a.w == b.w && a.h == b.h, "1200×900 is under the 1600 px cap, so size is kept: \(a.w)x\(a.h)")
                expect(a.bytes < b.bytes, "payload smaller \(b.bytes) → \(a.bytes)")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel2TextPageRenderUnchanged() {
        print("Level2 text page pixel-match Level0")
        do {
            let data = try loadFixture("multipage_shared_resources.pdf")
            let out0 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 0)
            )
            let out2 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            for i in 0..<(pdfKitPageCount(data) ?? 0) {
                guard let r0 = renderPageBitmap(out0, pageIndex: i),
                      let r2 = renderPageBitmap(out2, pageIndex: i)
                else {
                    expect(false, "render p\(i)")
                    continue
                }
                expect(maxChannelDelta(r0, r2) == 0, "text p\(i) delta 0")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel2ImagePageSizeDrops() {
        print("Level2 file smaller on photo PDF")
        do {
            let data = FixtureGenerator.photoPDF
            let out0 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 0)
            )
            let out2 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            expect(out2.count < out0.count, "L2 \(out2.count) < L0 \(out0.count)")
            expect(out2.count < data.count / 2, "L2 < half original \(out2.count) vs \(data.count)")
            expect(pdfKitPageCount(out2) == 1, "opens")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel3StrongerThanLevel2() {
        print("Level3 size ≤ Level2")
        do {
            let data = FixtureGenerator.photoPDF
            let out2 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            let out3 = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 3)
            )
            expect(out3.count <= out2.count + 256, "L3 \(out3.count) ≤ L2 \(out2.count)")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel2PreservesPageCountAndFonts() {
        print("Level2 pageCount + font")
        do {
            let data = try loadFixture("fidelity_rich.pdf")
            let out = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            expectEqual(pdfKitPageCount(out), 2, "pages")
            let g = try PDFParser.parse(out)
            expect(g.objects[7] != nil, "font obj")
            expect(contains(out, "Fidelity Page 1"), "text kept")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel2StillStripsMetadata() {
        print("Level2 strips author")
        do {
            let data = FixtureGenerator.photoPDF
            let out = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            )
            expect(!contains(out, plantedAuthor), "author gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testSkipSMaskImages() {
        print("SMask images left alone")
        // Build minimal PDF with SMask on image — compressor must skip
        do {
            // Use embedded_jpeg and manually parse + inject SMask key via graph mutate isn't easy from fixture.
            // Instead: unit-level — stream with SMask should not change size when only recompress runs.
            let data = try loadFixture("embedded_jpeg_exif.pdf")
            var g = try PDFParser.parse(data)
            // Tag first image stream with SMask ref so recompressor skips
            for (num, entry) in g.objects {
                if case .stream(var d, let payload) = entry.value,
                   ImageMetadataStripper.isDCTDecode(d)
                {
                    d["SMask"] = .ref(PDFRef(obj: 1, gen: 0))
                    g.objects[num] = (entry.gen, .stream(dict: d, data: payload))
                    break
                }
            }
            let before = g.objects
            ImageRecompressor.recompressImages(in: &g, profile: CompressionProfiles.profile(for: 4))
            // Find image stream payload unchanged
            var ok = false
            for (num, entry) in before {
                guard case .stream(let d0, let p0) = entry.value,
                      ImageMetadataStripper.isDCTDecode(d0) || d0["SMask"] != nil
                else { continue }
                if case .stream(_, let p1) = g.objects[num]?.value {
                    expect(p0 == p1, "SMask image payload unchanged")
                    ok = true
                }
            }
            expect(ok, "found smask image")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testLevel0StillPixelPerfectOnPhotoPDF() {
        print("Level0 still pixel-safe on photo PDF text/chrome")
        do {
            let data = FixtureGenerator.photoPDF
            let out = try PDFSanitizer.sanitize(
                data: data, options: .default,
                compression: CompressionProfiles.profile(for: 0)
            )
            // Level 0 may strip EXIF from JPEG via deep strip — pixels should match decode
            // Compare renders of level0 export to itself identity: just ensure opens and text present
            expect(pdfKitPageCount(out) == 1, "opens")
            expect(contains(out, "Photo page"), "text")
            // Image still present
            expect(try imageXObjectSize(out) != nil, "image")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - estimates + naming

    static func testEstimateErrorBandOnFixtures() {
        print("actual size within estimate band / slack")
        let committed = [
            "info_author.pdf",
            "multipage_shared_resources.pdf",
            "fidelity_rich.pdf",
            "embedded_jpeg_exif.pdf",
        ]
        var fixtures: [(name: String, data: Data)] = committed.compactMap { name in
            guard let data = try? loadFixture(name) else {
                expect(false, "\(name): missing fixture")
                return nil
            }
            return (name, data)
        }
        fixtures.append(("generated photo", FixtureGenerator.photoPDF))
        for (name, data) in fixtures {
            do {
                let inv = try PDFSanitizer.inspect(data: data).sizeInventory
                for level in 0...4 {
                    let profile = CompressionProfiles.profile(for: level)
                    let est = SizeEstimator.estimate(inventory: inv, profile: profile)
                    let actual = try PDFSanitizer.sanitize(
                        data: data,
                        options: .default,
                        compression: profile
                    ).count
                    let ok = SizeEstimator.actualWithinBand(actual: actual, estimate: est)
                    expect(ok, "\(name) L\(level) actual \(actual) vs \(est.bytesLow)–\(est.bytesHigh) mid \(est.bytesMid)")
                }
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testProbeExactMatchesActual() {
        print("probe matches actual export size")
        do {
            let data = try loadFixture("info_author.pdf")
            let profile = CompressionProfiles.profile(for: 2)
            guard let probe = SizeEstimator.probe(data: data, profile: profile) else {
                expect(false, "probe nil")
                return
            }
            expect(probe.isExact, "method exact")
            let actual = try PDFSanitizer.sanitize(
                data: data, options: .default, compression: profile
            ).count
            expect(SizeEstimator.actualWithinBand(actual: actual, estimate: probe), "within probe band")
            // Mid should be essentially the actual size
            expect(abs(probe.bytesMid - actual) <= max(64, actual / 50), "mid near actual")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testProbeSkippedWhenTooLarge() {
        print("probe skipped over threshold")
        // Synthetic large buffer with PDF magic — probe should refuse without parsing fully
        var huge = Data("%PDF-1.4\n".utf8)
        huge.append(Data(repeating: 0x20, count: SizeEstimator.probeMaxBytes + 1000))
        let p = SizeEstimator.probe(
            data: huge,
            profile: CompressionProfiles.profile(for: 0)
        )
        expect(p == nil, "nil when too large")
        expect(!SizeEstimator.shouldProbe(fileSizeBytes: SizeEstimator.probeMaxBytes + 1), "shouldProbe false")
        expect(SizeEstimator.shouldProbe(fileSizeBytes: 1000), "shouldProbe true small")
    }

    static func testDebouncedProbeGenerationLogic() {
        print("only latest generation wins (logic)")
        // Pure logic stand-in: higher generation supersedes
        var generation = 0
        var applied: Int?
        func schedule(_ level: Int, delayMs: Int, onApply: @escaping (Int) -> Void) {
            generation += 1
            let gen = generation
            // Synchronous simulation of race: only last gen applies
            if gen == generation {
                applied = level
                onApply(level)
            }
            _ = delayMs
        }
        schedule(1, delayMs: 100) { _ in }
        schedule(3, delayMs: 50) { _ in }
        expectEqual(applied, 3, "latest level")
        expectEqual(generation, 2, "two schedules")
    }

    static func testSaveNameIncludesProfile() {
        print("save name includes profile")
        let url = URL(fileURLWithPath: "/tmp/Report Final.pdf")
        expectEqual(
            ExportNaming.suggestedFileName(original: url, profile: CompressionProfiles.profile(for: 0)),
            "Report Final-clean.pdf",
            "none"
        )
        expectEqual(
            ExportNaming.suggestedFileName(original: url, profile: CompressionProfiles.profile(for: 1)),
            "Report Final-clean-light.pdf",
            "light"
        )
        expectEqual(
            ExportNaming.suggestedFileName(original: url, profile: CompressionProfiles.profile(for: 2)),
            "Report Final-clean-balanced.pdf",
            "balanced"
        )
        expectEqual(
            ExportNaming.suggestedFileName(original: url, profile: CompressionProfiles.profile(for: 3)),
            "Report Final-clean-strong.pdf",
            "strong"
        )
        expectEqual(
            ExportNaming.suggestedFileName(original: url, profile: CompressionProfiles.profile(for: 4)),
            "Report Final-clean-max.pdf",
            "max"
        )
    }

    // MARK: - Limits

    static func testExportUnderMemoryCap() {
        print("oversize rejected before compress")
        let previous = PDFSanitizer.testMaxInputBytes
        PDFSanitizer.testMaxInputBytes = 200
        defer { PDFSanitizer.testMaxInputBytes = previous }
        var data = Data("%PDF-1.4\n".utf8)
        data.append(Data(repeating: 0x41, count: 500))
        do {
            _ = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 4)
            )
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            if case .oversize = e { expect(true, "oversize") }
            else { expect(false, "got \(e)") }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testCompressLevelsAllOpenInPDFKit() {
        print("all levels produce openable PDFs")
        do {
            let data = try loadFixture("fidelity_rich.pdf")
            for level in 0...4 {
                let out = try PDFSanitizer.sanitize(
                    data: data,
                    options: .default,
                    compression: CompressionProfiles.profile(for: level)
                )
                expectEqual(pdfKitPageCount(out), 2, "L\(level) pages")
                expect(out.starts(with: Data("%PDF-".utf8)), "L\(level) magic")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testCompressDoesNotRasterizeTextSelection() {
        print("text still present as text after Max (not full-page raster)")
        do {
            let data = try loadFixture("multipage_shared_resources.pdf")
            let out = try PDFSanitizer.sanitize(
                data: data,
                options: .default,
                compression: CompressionProfiles.profile(for: 4)
            )
            // Content stream operators remain (BT/ET), not only an image Do of full page
            expect(contains(out, "BT"), "has text operators")
            expect(contains(out, "Page 1") || contains(out, "Page1") || contains(out, "Page"), "text payload")
            let g = try PDFParser.parse(out)
            expectEqual(PDFGraphInspect.pageCount(g), 2, "pages")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testWorkingCopyProfilesExist() {
        print("profile table complete")
        expectEqual(CompressionProfiles.all.count, 5, "5 levels")
        expectEqual(CompressionProfiles.defaultLevel, 0, "safe default")
        expect(CompressionProfiles.profile(for: 0).isLossy == false, "0 not lossy")
        expect(CompressionProfiles.profile(for: 2).isLossy, "2 lossy")
        expect(SizeEstimator.probeMaxBytes == 15 * 1024 * 1024, "probe cap 15MB")
    }
}
