import Foundation
import PDFKit

extension CleardropTests {
    // MARK: - What stays

    static func testResidualFindingsListed() {
        print("Review lists what stays in the file, and it really does stay")
        do {
            let data = FixtureGenerator.residualsPDF
            expectEqual(pdfKitPageCount(data), 1, "fixture opens")
            let inspection = try PDFSanitizer.inspect(data: data)
            let summary = ReviewSummary(inspection)
            let labels = summary.residual.map(\.label)
            expectEqual(labels, ["JavaScript", "Attached files", "Color profiles"], "residual rows")
            expect(summary.residual.allSatisfy { $0.category == ReviewSummary.residualCategory }, "residual category")
            expect(summary.removable.contains { $0.label == "Author" }, "author is listed as removable")
            expect(!summary.removable.contains { labels.contains($0.label) }, "nothing is listed as both removed and staying")

            let result = try PDFSanitizer.sanitizeWithReport(data: data, options: .default)
            expect(!contains(result.data, plantedAuthor), "author removed")
            expect(contains(result.data, FixtureGenerator.residualScriptMark), "script is still in the saved copy")
            expect(contains(result.data, FixtureGenerator.residualAttachmentMark), "attachment is still in the saved copy")
            expect(contains(result.data, FixtureGenerator.residualProfileMark), "colour profile is still in the saved copy")
            expectEqual(result.report.stillPresent.map(\.label), labels, "report names the same things")
            expect(result.report.message.contains("Still in the file: JavaScript, Attached files, Color profiles."), "done message names them")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testResidualsIgnoreUnreachable() {
        print("A script nothing references is dropped, so it is not listed as staying")
        do {
            let data = FixtureGenerator.unreachableScriptPDF
            let inspection = try PDFSanitizer.inspect(data: data)
            expect(inspection.residuals.isEmpty, "no residual rows")
            expect(!inspection.hasJS, "hasJS is false")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, FixtureGenerator.residualScriptMark), "and it is indeed gone")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testStandingNoteAndEmptyState() {
        print("Standing note and empty state say what was checked and what is not touched")
        let note = ReviewSummary.standingNote
        for word in ["text", "images", "fonts"] {
            expect(note.contains(word), "standing note mentions \(word)")
        }
        expect(!ReviewSummary.emptyTitle.lowercased().contains("obvious"), "empty title is not vague")
        for word in ["document info", "XMP", "file ID", "annotation", "JPEG"] {
            expect(ReviewSummary.emptyBody.contains(word), "empty state names \(word)")
        }
        do {
            // A file with no Info, no ID, no XMP: nothing removable.
            let bare = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
            let summary = ReviewSummary(try PDFSanitizer.inspect(data: bare))
            expect(summary.removable.isEmpty, "bare file has nothing removable")
            expect(summary.summaryLine.contains("no removable metadata found"), "summary line says so")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Signatures

    static func testEmptySignatureFieldAccepted() {
        print("An unsigned signature field is not a signature")
        do {
            let data = FixtureGenerator.signatureFieldPDF()
            let inspection = try PDFSanitizer.inspect(data: data)
            expect(!inspection.isSigned, "not reported as signed")
            expectEqual(inspection.emptySignatureFieldCount, 1, "one empty field")
            expect(inspection.residuals.contains { $0.label == "Empty signature field" }, "listed as staying")

            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(!contains(out, plantedAuthor), "author removed")
            expect(contains(out, "/FT /Sig"), "the field is kept")
            expect(contains(out, "(Signature1)"), "the field name is kept")
            expectEqual(pdfKitPageCount(out), 1, "output opens")

            let nullValue = FixtureGenerator.signatureFieldPDF(value: "/V null")
            expect(!(try PDFSanitizer.inspect(data: nullValue)).isSigned, "/V null is unsigned")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFilledSignatureRefused() {
        print("A signed signature field is refused")
        let byReference = FixtureGenerator.signatureFieldPDF(
            value: "/V 7 0 R",
            extra: [(7, FixtureGenerator.signatureDictionary)]
        )
        expectRefusal(byReference, "field with /V pointing at a signature") { $0 == .signed }
        let inline = FixtureGenerator.signatureFieldPDF(
            value: "/V << /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 1 2 3] /Contents <3080> >>"
        )
        expectRefusal(inline, "field with an inline signature") { $0 == .signed }
        let opaqueValue = FixtureGenerator.signatureFieldPDF(value: "/V (anything)")
        expectRefusal(opaqueValue, "field with any non-null /V") { $0 == .signed }
        do {
            let inspection = try PDFSanitizer.inspect(data: byReference)
            expect(inspection.isSigned, "inspect reports signed")
            expect(inspection.residuals.isEmpty, "a signed file lists no empty field")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testByteRangeAloneRefused() {
        print("A signature dictionary outside any field is still refused")
        var objects = FixtureGenerator.onePageObjects(catalogExtra: "/Custom 6 0 R")
        objects.append((6, Data("<< /ByteRange [0 1 2 3] /Contents <3080> >>".utf8)))
        expectRefusal(FixtureGenerator.classicPDF(objects: objects), "untyped /ByteRange + /Contents") { $0 == .signed }

        objects = FixtureGenerator.onePageObjects(catalogExtra: "/Perms 6 0 R")
        objects.append((6, Data("<< /DocMDP 7 0 R >>".utf8)))
        objects.append((7, Data("<< /Type /Sig >>".utf8)))
        expectRefusal(FixtureGenerator.classicPDF(objects: objects), "catalog /Perms stored as an object") { $0 == .signed }
    }

    // MARK: - Copy matches action

    static func testActionTitleMatchesAction() {
        print("The button names what will happen")
        do {
            let withMetadata = ReviewSummary(try PDFSanitizer.inspect(data: try loadFixture("info_author.pdf")))
            let bare = ReviewSummary(try PDFSanitizer.inspect(
                data: FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
            ))
            var titles: [String] = []
            for level in 0...4 {
                let profile = CompressionProfiles.profile(for: level)
                let a = withMetadata.actionTitle(for: profile)
                let b = bare.actionTitle(for: profile)
                titles += [a, b]
                expect(a.contains("Remove metadata"), "L\(level) with metadata: \(a)")
                expect(!b.lowercased().contains("metadata") && !b.lowercased().contains("clean"), "L\(level) with none claims no removal: \(b)")
                expectEqual(a.lowercased().contains("compress"), level >= 2, "L\(level) mentions compression only when it compresses")
                expectEqual(b.lowercased().contains("compress"), level >= 2, "L\(level) bare mentions compression only when it compresses")
            }
            for title in titles {
                expect(!title.lowercased().contains(" all "), "no \"all\" in \"\(title)\"")
                expect(title.hasSuffix("…"), "\"\(title)\" opens a save panel")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testDoneReportMatchesOutput() {
        print("The done message is built from the saved bytes")
        do {
            // Nothing to remove: must not claim that metadata was removed.
            let bare = FixtureGenerator.classicPDF(objects: FixtureGenerator.onePageObjects())
            let none = try PDFSanitizer.sanitizeWithReport(data: bare, options: .default).report
            expectEqual(none.changeCount, 0, "bare file: nothing changed")
            expect(none.message.contains("No metadata was found to remove"), "bare file message")
            expect(!none.message.contains("Removed"), "bare file message does not say Removed")

            // Author, producer, title, creator, plus the file ID.
            let rich = try PDFSanitizer.sanitizeWithReport(data: try loadFixture("info_author.pdf"), options: .default)
            let before = ReviewSummary(try PDFSanitizer.inspect(data: try loadFixture("info_author.pdf")))
            expectEqual(rich.report.changeCount, before.removable.count, "every removable row is reported as removed")
            expect(rich.report.leftBehind.isEmpty, "nothing left behind")
            expect(rich.report.message.contains("Removed \(before.removable.count) metadata items"), "count in message: \(rich.report.message)")
            let after = ReviewSummary(try PDFSanitizer.inspect(data: rich.data))
            expect(after.removable.allSatisfy { $0.label == "Trailer file ID" }, "re-inspecting the copy shows only its new file ID")

            // If the strip is deliberately incomplete, the report says so instead of claiming success.
            let partial = try PDFSanitizer.sanitizeWithReport(data: try loadFixture("page_metadata.pdf"), options: .documentLevelOnly).report
            expect(partial.leftBehind.contains { $0.label == "Page or object XMP metadata" }, "left-behind row found")
            expect(partial.message.contains("still present"), "message admits it")

            // Compression wording follows the measured sizes.
            let photo = try PDFSanitizer.sanitizeWithReport(
                data: FixtureGenerator.photoPDF, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            ).report
            expect(photo.bytesAfter < photo.bytesBefore, "photo file shrank")
            expect(photo.message.contains("Compression re-encoded 1 of 1 image."), "says what compression did")
            expect(photo.message.contains("The file went from"), "says it shrank")
            let text = try PDFSanitizer.sanitizeWithReport(
                data: bare, options: .default,
                compression: CompressionProfiles.profile(for: 2)
            ).report
            expect(text.message.contains("Compression found nothing it could shrink in this file."), "says when compression did nothing")
            expect(!text.message.contains("The file went from"), "and does not claim a reduction")

            for report in [none, rich.report, partial, photo, text] {
                expect(report.message.hasSuffix("Your original file was not changed."), "ends with the original-untouched line")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testProcessReturnsReport() {
        print("process(from:to:) returns the same report")
        do {
            let src = try writeTemp(named: "report-src.pdf", data: try loadFixture("info_author.pdf"))
            let dest = tempURL(named: "report-clean.pdf")
            defer {
                try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: dest)
            }
            let report = try PDFSanitizer.process(from: src, to: dest, options: .default)
            expect(report.changeCount > 0, "report has changes")
            expectEqual(report.bytesAfter, try Data(contentsOf: dest).count, "report size is the size on disk")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Errors

    static func testErrorMessagesDistinct() {
        print("Unsupported and damaged files get different messages, and the README lists them")
        let unsupported = PDFSanitizerError.unsupportedStructure("x").errorDescription ?? ""
        let damaged = PDFSanitizerError.corrupt("x").errorDescription ?? ""
        expect(unsupported != damaged, "different text")
        expect(!unsupported.isEmpty && !damaged.isEmpty, "both present")

        let all: [PDFSanitizerError] = [
            .notPDF, .cannotRead, .encrypted, .signed, .corrupt("x"), .unsupportedStructure("x"),
            .oversize(limitMB: 100), .cannotWrite(URL(fileURLWithPath: "/tmp/x.pdf")), .emptyInput,
        ]
        let readme = (try? String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        for error in all {
            let text = error.errorDescription ?? ""
            expect(text.count <= 60, "short: \(text)")
            expect(readme.contains("`\(text)`"), "README error table lists \"\(text)\"")
        }
    }
}
