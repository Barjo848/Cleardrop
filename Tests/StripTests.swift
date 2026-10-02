import Foundation
import PDFKit

extension CleardropTests {
    // Planted only in generated fixtures for these tests.
    static let plantedIndirectAuthor = "PLANTED_INDIRECT_AUTHOR_CLEARDROP_e606"
    static let plantedNestedInfo = "PLANTED_NESTED_INFO_CLEARDROP_f707"
    static let plantedPagePiece = "PLANTED_PAGE_PIECE_CLEARDROP_0808"
    static let plantedOrphan = "PLANTED_ORPHAN_CLEARDROP_0909"

    /// Committed fixtures that can be cleaned, plus the generated ones.
    static func cleanableFixtures() -> [(name: String, data: Data)] {
        var fixtures: [(name: String, data: Data)] = []
        let dir = repoRoot.appendingPathComponent("Tests/Fixtures")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let name = url.lastPathComponent
            if name == "encrypted_user.pdf" || name == "signed_preview.pdf" { continue }
            if let data = try? Data(contentsOf: url) { fixtures.append((name, data)) }
        }
        fixtures.append(("generated photo", FixtureGenerator.photoPDF))
        fixtures.append(("generated two-section", FixtureGenerator.twoSectionPDF))
        fixtures.append(("generated indirect info", FixtureGenerator.indirectInfoPDF))
        fixtures.append(("generated page PieceInfo", FixtureGenerator.pagePieceInfoPDF))
        fixtures.append(("generated orphan", FixtureGenerator.orphanObjectPDF))
        fixtures.append(("generated shared object", FixtureGenerator.sharedWithInfoPDF))
        return fixtures
    }

    // MARK: - Reachability

    static func testIndirectInfoStringGone() {
        print("An Info value stored as its own object is removed")
        do {
            let data = FixtureGenerator.indirectInfoPDF
            expect(contains(data, plantedIndirectAuthor), "source has the indirect author")
            expectEqual(try PDFSanitizer.inspect(data: data).pageCount, 1, "one page")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedIndirectAuthor), "indirect author absent from output bytes")
            expectEqual(pdfKitPageCount(out), 1, "output opens")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testNestedInfoChildGone() {
        print("A dictionary that only Info pointed to is removed")
        do {
            let data = FixtureGenerator.indirectInfoPDF
            expect(contains(data, plantedNestedInfo), "source has the nested value")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedNestedInfo), "nested value absent from output bytes")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testPagePieceInfoGone() {
        print("PieceInfo on a page and on a form XObject is removed")
        do {
            let data = FixtureGenerator.pagePieceInfoPDF
            expect(contains(data, plantedPagePiece), "source has page PieceInfo")
            let info = try PDFSanitizer.inspect(data: data)
            expect(info.hasPieceInfo, "inspect reports PieceInfo that is not on the catalog")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedPagePiece), "planted PieceInfo value absent")
            expect(!contains(out, "/PieceInfo"), "no PieceInfo key")
            expect(!contains(out, "/LastModified"), "no LastModified key")
            expect(!(try PDFSanitizer.inspect(data: out)).hasPieceInfo, "re-inspect finds none")
            expectEqual(pdfKitPageCount(out), 1, "output opens")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testOrphanObjectNotWritten() {
        print("An object nothing references is not written")
        do {
            let data = FixtureGenerator.orphanObjectPDF
            expect(contains(data, plantedOrphan), "source has the orphan")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedOrphan), "orphan absent from output bytes")
            let graph = try PDFParser.parse(out)
            let reached = PDFReachability.reachableObjects(in: graph)
            expectEqual(Set(graph.objects.keys), reached, "every written object is reachable")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testSharedObjectSurvivesStrip() {
        print("An object shared between Info and a page is kept")
        do {
            let data = FixtureGenerator.sharedWithInfoPDF
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let graph = try PDFParser.parse(out)
            expect(!PDFGraphInspect.hasInfoDict(graph), "Info detached")
            expect(graph.objects[5] != nil, "shared font object still written")
            expect(pdfKitText(out).contains("Hello"), "text still drawn with the shared font")
            guard let before = renderPageBitmap(data, pageIndex: 0),
                  let after = renderPageBitmap(out, pageIndex: 0)
            else {
                expect(false, "render")
                return
            }
            expectEqual(maxChannelDelta(before, after), 0, "pixel delta")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testIdentityRewriteDoesNotSweep() {
        print("Identity rewrite keeps every object (it is the round-trip control)")
        do {
            let out = try PDFSanitizer.sanitize(data: FixtureGenerator.orphanObjectPDF, options: .identityRewriteOnly)
            expect(contains(out, plantedOrphan), "orphan kept when nothing is stripped")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Whole-corpus checks

    static func testSweepKeepsEveryPageResource() {
        print("Sweep removes nothing a page needs: pixel-exact at level 0")
        for (name, data) in cleanableFixtures() {
            do {
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                let pages = pdfKitPageCount(data) ?? 0
                expectEqual(pdfKitPageCount(out), Optional(pages), "\(name): page count")
                for i in Array(Set([0, pages / 2, pages - 1])).sorted() where i >= 0 && i < pages {
                    guard let before = renderPageBitmap(data, pageIndex: i, scale: 1.0),
                          let after = renderPageBitmap(out, pageIndex: i, scale: 1.0)
                    else {
                        expect(false, "\(name) p\(i): render")
                        continue
                    }
                    expectEqual(maxChannelDelta(before, after), 0, "\(name) p\(i): pixel delta")
                }
                let graph = try PDFParser.parse(out)
                expectEqual(
                    Set(graph.objects.keys),
                    PDFReachability.reachableObjects(in: graph),
                    "\(name): every written object is reachable"
                )
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }

    static func testNoPlantedTokenSurvives() {
        print("No planted metadata token is present in any cleaned output")
        for (name, data) in cleanableFixtures() {
            do {
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                expect(!contains(out, "PLANTED_"), "\(name): no planted token")
            } catch {
                expect(false, "\(name): \(error)")
            }
        }
    }
}
