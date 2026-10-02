import Foundation
import PDFKit

extension CleardropTests {
    // MARK: - Helpers

    /// Expect `sanitize` and `inspect` both to throw `.corrupt` for `data`.
    static func expectCorrupt(_ data: Data, _ what: String) {
        for (label, run) in [
            ("sanitize", { _ = try PDFSanitizer.sanitize(data: data, options: .default) }),
            ("inspect", { _ = try PDFSanitizer.inspect(data: data) }),
        ] as [(String, () throws -> Void)] {
            do {
                try run()
                expect(false, "\(what): \(label) should throw")
            } catch let e as PDFSanitizerError {
                if case .corrupt = e {
                    expect(true, "\(what): \(label) throws corrupt")
                } else {
                    expect(false, "\(what): \(label) threw \(e), want corrupt")
                }
            } catch {
                expect(false, "\(what): \(label) threw \(error)")
            }
        }
    }

    static func pdfKitText(_ data: Data) -> String {
        PDFDocument(data: data)?.string ?? ""
    }

    // MARK: - Incremental files

    static func testIncrementalPrevKeepsPages() {
        print("Incremental save: objects in older sections are kept")
        do {
            let data = FixtureGenerator.twoSectionPDF
            expectEqual(pdfKitPageCount(data), 2, "fixture has two pages")

            let info = try PDFSanitizer.inspect(data: data)
            expectEqual(info.pageCount, 2, "inspect sees both pages")
            expect(info.author == plantedAuthor, "inspect sees the author from the newest section")

            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expectEqual(pdfKitPageCount(out), 2, "output has both pages")
            let text = pdfKitText(out)
            expect(text.contains("Hello"), "first page text survives")
            expect(text.contains("Second"), "second page text survives")
            expect(!contains(out, plantedAuthor), "planted author gone")
            expect(!contains(out, "/Prev"), "output is a single section")
            for i in 0..<2 {
                guard let before = renderPageBitmap(data, pageIndex: i),
                      let after = renderPageBitmap(out, pageIndex: i)
                else {
                    expect(false, "render page \(i)")
                    continue
                }
                expectEqual(maxChannelDelta(before, after), 0, "page \(i) pixel delta")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testIncrementalNewestObjectWins() {
        print("Incremental save: a replaced object uses its newest version")
        do {
            let base = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects(text: "Old"))
            let updated = FixtureGenerator.appendingUpdate(
                to: base,
                objects: [(4, FixtureGenerator.streamObject(
                    dict: "",
                    payload: Data("BT /F1 12 Tf 72 700 Td (New) Tj ET".utf8)
                ))],
                size: 6
            )
            let out = try PDFSanitizer.sanitize(data: updated, options: .default)
            let text = pdfKitText(out)
            expect(text.contains("New"), "newest content shown")
            expect(!contains(out, "(Old)"), "superseded content stream is not written")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testCyclicPrevThrows() {
        print("Cyclic /Prev chains are refused")
        let base = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
        let selfCycle = FixtureGenerator.appendingUpdate(
            to: base,
            objects: [(6, Data("<< /Note (update) >>".utf8))],
            size: 7,
            prev: .itself
        )
        expectCorrupt(selfCycle, "section pointing at itself")
        expectCorrupt(FixtureGenerator.mutualPrevCyclePDF, "two sections pointing at each other")
    }

    static func testBadPrevOffsetThrows() {
        print("/Prev outside the file is refused")
        let base = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
        let updated = FixtureGenerator.appendingUpdate(
            to: base,
            objects: [(6, Data("<< /Note (update) >>".utf8))],
            size: 7,
            prev: .offset(99_999_999)
        )
        expectCorrupt(updated, "/Prev past the end")
    }

    // MARK: - Producer quirks

    static func testQuartzPhantomEntryAccepted() {
        print("An in-use entry at offset 0 (written by Quartz for unused numbers) is not an object")
        do {
            var objects = FixtureGenerator.onePageObjects()
            objects.append((8, Data("<< /Author (\(plantedAuthor)) /Producer (macOS Quartz PDFContext) >>".utf8)))
            // Objects 6 and 7 are listed as in use at offset 0; the page also refers to 7.
            objects[2] = (3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Unused 7 0 R >>".utf8))
            let data = FixtureGenerator.classicPDF(
                objects: objects, trailerExtra: "/Info 8 0 R", version: "1.3", phantomInUse: [6, 7]
            )
            expect(contains(data, "0000000000 00000 n"), "fixture has the phantom entries")
            expectEqual(pdfKitPageCount(data), 1, "PDFKit opens the fixture")

            let graph = try PDFParser.parse(data)
            expect(graph.objects[6] == nil && graph.objects[7] == nil, "phantom numbers are not objects")
            expectEqual(try PDFSanitizer.inspect(data: data).pageCount, 1, "inspect")

            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expectEqual(pdfKitPageCount(out), 1, "output opens")
            expect(pdfKitText(out).contains("Hello"), "text survives")
            expect(!contains(out, plantedAuthor), "author removed")
            expect(!contains(out, "Quartz"), "producer removed")
            expect(!contains(out, "0000000000 00000 n"), "the output has no phantom entry")
            guard let a = renderPageBitmap(data, pageIndex: 0), let b = renderPageBitmap(out, pageIndex: 0) else {
                expect(false, "render")
                return
            }
            expectEqual(maxChannelDelta(a, b), 0, "pixel delta")
        } catch {
            expect(false, "\(error)")
        }
        // A wrong offset anywhere else is still damage.
        var broken = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
        if let entry = broken.range(of: Data("0000000009 00000 n".utf8)) {
            broken.replaceSubrange(entry, with: Data("0000000040 00000 n".utf8))
        }
        expectCorrupt(broken, "an entry pointing into the middle of another object")
    }

    // MARK: - Hostile and damaged input

    static func testDeepNestingThrowsNotCrashes() {
        print("Deep nesting is refused without exhausting the stack")
        let depth = 200_000
        var body = Data(repeating: UInt8(ascii: "["), count: depth)
        body.append(Data(repeating: UInt8(ascii: "]"), count: depth))
        var objects = FixtureGenerator.onePageObjects()
        objects.append((6, body))
        expectCorrupt(FixtureGenerator.classicPDF(objects: objects), "200,000 nested arrays")

        var dictBody = Data()
        for _ in 0..<depth { dictBody.append(Data("<</A ".utf8)) }
        dictBody.append(Data("null".utf8))
        for _ in 0..<depth { dictBody.append(Data(">>".utf8)) }
        objects[objects.count - 1] = (6, dictBody)
        expectCorrupt(FixtureGenerator.classicPDF(objects: objects), "200,000 nested dictionaries")

        // Nesting that real files use is still accepted.
        var shallow = Data(repeating: UInt8(ascii: "["), count: 40)
        shallow.append(Data(repeating: UInt8(ascii: "]"), count: 40))
        objects[objects.count - 1] = (6, shallow)
        do {
            _ = try PDFSanitizer.sanitize(data: FixtureGenerator.classicPDF(objects: objects), options: .default)
            expect(true, "40 levels accepted")
        } catch {
            expect(false, "40 levels should be accepted: \(error)")
        }
    }

    static func testLyingLengthThrows() {
        print("A stream whose /Length is wrong is refused, not truncated")
        let payload = Data("BT /F1 12 Tf 72 700 Td (Hello) Tj ET".utf8)
        func pdf(length: String) -> Data {
            var stream = Data("<< /Length \(length) >>\nstream\n".utf8)
            stream.append(payload)
            stream.append(Data("\nendstream".utf8))
            var objects = FixtureGenerator.onePageObjects()
            objects[3] = (4, stream)
            return FixtureGenerator.classicPDF(objects: objects)
        }
        expectCorrupt(pdf(length: "5"), "/Length too short")
        expectCorrupt(pdf(length: "\(payload.count + 9)"), "/Length too long")
        expectCorrupt(pdf(length: "99999999"), "/Length past the end of the file")
        expectCorrupt(pdf(length: "-1"), "negative /Length")
        expectCorrupt(pdf(length: "(text)"), "/Length that is not a number")
        do {
            let out = try PDFSanitizer.sanitize(data: pdf(length: "\(payload.count)"), options: .default)
            expect(contains(out, "(Hello) Tj ET"), "correct /Length accepted with content intact")
        } catch {
            expect(false, "correct /Length should be accepted: \(error)")
        }
    }

    static func testUnterminatedStringsThrow() {
        print("Unterminated strings are refused")
        var objects = FixtureGenerator.onePageObjects()
        objects.append((6, Data("<< /Note (never closed >>".utf8)))
        expectCorrupt(FixtureGenerator.classicPDF(objects: objects), "literal string without )")
        objects[objects.count - 1] = (6, Data("<< /Note <4142".utf8))
        expectCorrupt(FixtureGenerator.classicPDF(objects: objects), "hex string without >")
    }

    static func testUnresolvablePagesThrows() {
        print("A page tree that cannot be followed is refused")
        let good = FixtureGenerator.onePageObjects()

        let noCatalog = FixtureGenerator.classicPDF(objects: Array(good.dropFirst()))
        expectCorrupt(noCatalog, "missing catalog object")

        var missingPages = good
        missingPages[0] = (1, Data("<< /Type /Catalog /Pages 9 0 R >>".utf8))
        expectCorrupt(FixtureGenerator.classicPDF(objects: missingPages), "/Pages points at nothing")

        var missingKid = good
        missingKid[1] = (2, Data("<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>".utf8))
        expectCorrupt(FixtureGenerator.classicPDF(objects: missingKid), "a kid points at nothing")

        var cycle = good
        cycle[1] = (2, Data("<< /Type /Pages /Kids [2 0 R] /Count 1 >>".utf8))
        expectCorrupt(FixtureGenerator.classicPDF(objects: cycle), "page tree contains itself")

        var empty = good
        empty[1] = (2, Data("<< /Type /Pages /Kids [] /Count 0 >>".utf8))
        expectCorrupt(FixtureGenerator.classicPDF(objects: empty), "no pages")
    }

    // MARK: - Exact round trip

    static func testNameBytesRoundTrip() {
        print("Names keep their exact bytes")
        do {
            var objects = FixtureGenerator.onePageObjects(catalogExtra: "/Keep 6 0 R")
            objects.append((6, Data("<< /Na#E9me /V#FFal /Sp#20ace (x) /Plain /A#42C >>".utf8)))
            let out = try PDFSanitizer.sanitize(data: FixtureGenerator.classicPDF(objects: objects), options: .default)
            expect(contains(out, "/Na#E9me /V#FFal"), "non-ASCII name bytes written back as the same escapes")
            expect(contains(out, "/Sp#20ace"), "escaped space kept")
            expect(contains(out, "/Plain /ABC"), "an escaped ASCII letter is the same name as the letter")
            expect(!contains(out, "#EF#BF#BD"), "no replacement character")

            let graph = try PDFParser.parse(out)
            let dict = graph.objects[6].flatMap { PDFGraphInspect.dict(of: $0.value) }
            let key = PDFName.string(fromBytes: [0x4E, 0x61, 0xE9, 0x6D, 0x65])
            expect(dict?[key] == .name(PDFName.string(fromBytes: [0x56, 0xFF, 0x61, 0x6C])), "parsed key and value hold the raw bytes")
        } catch {
            expect(false, "\(error)")
        }
        let allBytes = (1...255).map { UInt8($0) }
        expect(PDFName.bytes(of: PDFName.string(fromBytes: allBytes)) == allBytes, "every byte value round-trips")
    }

    static func testRealsNeverExponent() {
        print("Reals are written as plain decimals")
        let cases: [(Double, String)] = [
            (0.00001, "0.00001"),
            (-0.000004, "-0.000004"),
            (123456789012345.5, "123456789012345.5"),
            (1e20, "100000000000000000000"),
            (612.0, "612"),
            (0.5, "0.5"),
            (-12.75, "-12.75"),
            (1.5e-10, "0.00000000015"),
        ]
        for (value, want) in cases {
            expectEqual(PDFWriter.formatReal(value), want, "format \(value)")
        }
        for value in [0.1, 1.0 / 3.0, 595.276, 0.000123456789, 98765.4321e-7, -3.0e-9] {
            let text = PDFWriter.formatReal(value)
            expect(!text.lowercased().contains("e"), "\(text) has no exponent")
            expect(Double(text) == value, "\(text) reads back as the same number")
        }
        do {
            var objects = FixtureGenerator.onePageObjects(catalogExtra: "/Keep 6 0 R")
            objects.append((6, Data("<< /Tiny 0.00001 /Big 123456789012345.5 /Neg -.000004 >>".utf8)))
            let out = try PDFSanitizer.sanitize(data: FixtureGenerator.classicPDF(objects: objects), options: .default)
            expect(contains(out, "/Tiny 0.00001"), "small real kept")
            expect(contains(out, "/Big 123456789012345.5"), "large real kept exactly")
            expect(contains(out, "/Neg -0.000004"), "negative small real kept")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Page count invariant

    static func testPageCountInvariantOnAllFixtures() {
        print("Page count: PDFKit before == inspect == PDFKit after, for every cleanable fixture")
        var fixtures: [(name: String, data: Data)] = []
        let dir = repoRoot.appendingPathComponent("Tests/Fixtures")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        expect(files.count >= 12, "committed fixtures found (\(files.count))")
        for url in files {
            let name = url.lastPathComponent
            if name == "encrypted_user.pdf" || name == "signed_preview.pdf" { continue }
            if let data = try? Data(contentsOf: url) { fixtures.append((name, data)) }
        }
        fixtures.append(("generated photo", FixtureGenerator.photoPDF))
        fixtures.append(("generated two-section", FixtureGenerator.twoSectionPDF))

        for (name, data) in fixtures {
            do {
                let before = pdfKitPageCount(data)
                let inspected = try PDFSanitizer.inspect(data: data).pageCount
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                expect((before ?? 0) > 0, "\(name): opens with pages")
                expectEqual(Optional(inspected), before, "\(name): inspect page count")
                expectEqual(pdfKitPageCount(out), before, "\(name): output page count")
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }
}
