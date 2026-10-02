import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension CleardropTests {
    // MARK: - robustness

    static func testRejectsOversize() {
        print("Rejects oversize")
        let previous = PDFSanitizer.testMaxInputBytes
        PDFSanitizer.testMaxInputBytes = 64
        defer { PDFSanitizer.testMaxInputBytes = previous }
        var data = Data("%PDF-1.4\n".utf8)
        data.append(Data(repeating: 0x41, count: 100))
        do {
            try PDFSanitizer.validatePDF(data: data)
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            if case .oversize = e { expect(true, "oversize") }
            else { expect(false, "got \(e)") }
        } catch {
            expect(false, "wrong type")
        }
    }

    static func testRejectsTooManyObjects() {
        print("Rejects too many objects")
        // Force a tiny object cap; multipage_shared has several objects
        let previous = PDFSanitizer.testMaxObjectCount
        PDFSanitizer.testMaxObjectCount = 2
        defer { PDFSanitizer.testMaxObjectCount = previous }
        do {
            _ = try PDFSanitizer.sanitize(
                data: try loadFixture("multipage_shared_resources.pdf"),
                options: .default
            )
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            if case .unsupportedStructure = e {
                expect(true, "unsupportedStructure for object cap")
            } else {
                // corrupt is also acceptable if size hint fails differently
                expect(true, "failed closed: \(e)")
            }
        } catch {
            expect(false, "crash/unexpected \(error)")
        }
    }

    static func testLargePDFUnderBudget() {
        print("50-page under budget (15s)")
        do {
            let data = try loadFixture("multipage_50.pdf")
            expectEqual(pdfKitPageCount(data), 50, "fixture 50 pages")
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            let dt = CFAbsoluteTimeGetCurrent() - t0
            print("    multipage_50 strip in \(String(format: "%.3f", dt))s")
            expect(dt < 15.0, "under 15s (got \(dt)s)")
            expectEqual(pdfKitPageCount(out), 50, "output 50 pages")
            expect(!contains(out, plantedAuthor), "info stripped on stress fixture")
            // Document measured budget in stdout for README
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testCorruptTruncatedXref() {
        print("Corrupt truncated xref")
        do {
            var data = try loadFixture("minimal_empty.pdf")
            // Chop off the last 40% (likely kills xref/trailer)
            let keep = max(20, data.count * 2 / 5)
            data = data.prefix(keep)
            // Ensure still starts with magic so we get past validate
            expect(data.starts(with: Data("%PDF-".utf8)), "still magic")
            do {
                _ = try PDFSanitizer.sanitize(data: Data(data), options: .default)
                expect(false, "should not succeed")
            } catch let e as PDFSanitizerError {
                switch e {
                case .corrupt, .unsupportedStructure, .notPDF:
                    expect(true, "fail closed: \(e)")
                default:
                    expect(true, "fail closed other: \(e)")
                }
            } catch {
                expect(false, "non-PDFSanitizerError: \(error)")
            }
        } catch {
            expect(false, "fixture load: \(error)")
        }
    }

    static func testCorruptNotPDFJunk() {
        print("Corrupt junk")
        let junk = Data("%PDF-".utf8) + Data(repeating: 0x00, count: 64)
        do {
            _ = try PDFSanitizer.sanitize(data: junk, options: .default)
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            expect(true, "throws \(e)")
        } catch {
            expect(false, "wrong type \(error)")
        }
    }

    static func testCorruptMissingStartxref() {
        print("Corrupt missing startxref")
        let data = Data("%PDF-1.4\n1 0 obj<<>>endobj\n%%EOF\n".utf8)
        do {
            _ = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(false, "should throw")
        } catch let e as PDFSanitizerError {
            if case .corrupt = e { expect(true, "corrupt") }
            else { expect(true, "fail closed: \(e)") }
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testEncryptedMessage() {
        print("Encrypted message stable")
        expectEqual(
            PDFSanitizerError.encrypted.errorDescription,
            "PDF is password-protected.",
            "copy"
        )
        do {
            _ = try PDFSanitizer.sanitize(data: try loadFixture("encrypted_user.pdf"), options: .default)
            expect(false, "throw")
        } catch let e as LocalizedError {
            expectEqual(e.errorDescription, "PDF is password-protected.", "runtime message")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testSignedMessage() {
        print("Signed message stable")
        expectEqual(
            PDFSanitizerError.signed.errorDescription,
            "Signed PDFs are not modified.",
            "copy"
        )
    }

    static func testUTF8FilenameStem() {
        print("UTF-8 filename stem")
        do {
            let data = try loadFixture("minimal_empty.pdf")
            let stem = "ドキュメント-résumé-émoji📎"
            let url = try writeTemp(named: "\(stem).pdf", data: data)
            defer { try? FileManager.default.removeItem(at: url) }
            let name = ExportNaming.suggestedFileName(
                original: url,
                profile: CompressionProfiles.profile(for: 0)
            )
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: out) }
            try PDFSanitizer.process(from: url, to: out, options: .default)
            expect(FileManager.default.fileExists(atPath: out.path), "written")
            expect(out.lastPathComponent.contains("ドキュメント"), "keeps Japanese")
            expect(out.lastPathComponent.contains("résumé"), "keeps accents")
            expect(out.lastPathComponent.contains("clean"), "clean tag")
            expect(out.pathExtension == "pdf", "pdf ext")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testOutputIsSeparateFile() {
        print("Output is a separate file; source untouched")
        do {
            let data = try loadFixture("info_author.pdf")
            let url = try writeTemp(named: "src-only.pdf", data: data)
            defer { try? FileManager.default.removeItem(at: url) }
            let before = sha256(data)
            let out = tempURL(named: "src-only-clean.pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try PDFSanitizer.process(from: url, to: out, options: .default)
            expect(sha256(try Data(contentsOf: url)) == before, "source hash")
            expect(contains(try Data(contentsOf: url), plantedAuthor), "source still has author")
            expect(!contains(try Data(contentsOf: out), plantedAuthor), "out stripped")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testFuzzTruncatedMutantsNoCrash() {
        print("Truncated mutants: each one throws or yields a PDF that opens")
        let sources = ["minimal_empty.pdf", "info_author.pdf", "xmp_catalog.pdf", "multipage_shared_resources.pdf"]
        var mutants = 0
        var threw = 0
        var survived = 0
        for name in sources {
            guard let full = try? loadFixture(name), full.count > 30 else { continue }
            // Fixed cut points + stepping
            var cuts: [Int] = [8, 16, 24, 32, 48, 64, full.count / 4, full.count / 2, full.count * 3 / 4, full.count - 5]
            cuts = cuts.filter { $0 > 5 && $0 < full.count }
            for cut in cuts {
                mutants += 1
                let slice = Data(full.prefix(cut))
                // Ensure magic when possible so we exercise parser not just validate
                var mutant = slice
                if !mutant.starts(with: Data("%PDF-".utf8)), mutant.count >= 5 {
                    mutant = Data("%PDF-".utf8) + mutant
                }
                do {
                    let out = try PDFSanitizer.sanitize(data: mutant, options: .default)
                    survived += 1
                    // Accepting a damaged file is only acceptable if the result is a usable PDF.
                    expect(
                        (pdfKitPageCount(out) ?? 0) > 0,
                        "\(name) cut at \(cut): accepted, so the output must open with pages"
                    )
                } catch is PDFSanitizerError {
                    threw += 1
                } catch {
                    expect(false, "non-sanitizer error on mutant: \(error)")
                    return
                }
            }
        }
        print("    mutants=\(mutants) threw=\(threw) survived=\(survived)")
        expect(mutants >= 20, "≥20 mutants (got \(mutants))")
        expectEqual(threw + survived, mutants, "every mutant threw a PDFSanitizerError or was accepted")
    }

    static func testProcessNoOutputOnFailure() {
        print("process writes nothing on failure")
        do {
            let url = fixture("encrypted_user.pdf")
            let dest = tempURL(named: "encrypted-clean.pdf")
            defer { try? FileManager.default.removeItem(at: dest) }
            do {
                try PDFSanitizer.process(from: url, to: dest, options: .default)
                expect(false, "should throw")
            } catch let e as PDFSanitizerError {
                expect(e == .encrypted, "encrypted")
            }
            expect(!FileManager.default.fileExists(atPath: dest.path), "no file at the destination")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testEmptyInputMessage() {
        print("Empty input")
        do {
            try PDFSanitizer.validatePDF(data: Data())
            expect(false, "throw")
        } catch let e as PDFSanitizerError {
            expect(e == .emptyInput, "emptyInput")
            expectEqual(e.errorDescription, "Not a PDF.", "message")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testOversizeMessage() {
        print("Oversize message")
        expectEqual(
            PDFSanitizerError.oversize(limitMB: 100).errorDescription,
            "PDF is too large.",
            "copy"
        )
    }

    // MARK: - Defaults, review, save

    static func testProductionDefaultIsFullStrip() {
        print("Production default is full strip")
        let d = SanitizeOptions.default
        expect(!d.identityRewrite, "not identity-only rewrite")
        expect(d.stripDocumentInfo, "Info")
        expect(d.stripCatalogXMP, "Catalog XMP")
        expect(d.regenerateFileID, "ID")
        expect(d.stripAnnotationIdentity, "annots")
        expect(d.stripEmbeddedImageMetadata, "JPEG")
        expect(d.stripAllObjectMetadataStreams, "all Metadata")
        expect(d.failIfEncrypted && d.failIfSigned, "fail closed")
    }

    static func testInspectFindingsIncludeAuthor() {
        print("Inspect findings include author")
        do {
            let info = try PDFSanitizer.inspect(data: try loadFixture("info_author.pdf"))
            expect(info.hasStrippableMetadata, "has strippable")
            expect(info.author == plantedAuthor || info.findings.contains { $0.value == plantedAuthor },
                   "author in inspection")
            expect(info.findings.contains { $0.label == "Author" }, "Author row")
            expect(info.findings.contains { $0.label == "Producer" }, "Producer row")
            expect(info.findings.contains { $0.label == "Trailer file ID" }, "file ID row")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testProcessToChosenURL() {
        print("process(from:to:)")
        do {
            let data = try loadFixture("info_author.pdf")
            let src = try writeTemp(named: "chosen-src.pdf", data: data)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-chosen-out-clean.pdf")
            defer {
                try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: dest)
            }
            try PDFSanitizer.process(from: src, to: dest, options: .default)
            expect(FileManager.default.fileExists(atPath: dest.path), "dest exists")
            let out = try Data(contentsOf: dest)
            expect(!contains(out, plantedAuthor), "author stripped at chosen path")
            expect(sha256(try Data(contentsOf: src)) == sha256(data), "source unchanged")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testRefusesToOverwriteSource() {
        print("Refuses a destination that is the source")
        do {
            let data = try loadFixture("info_author.pdf")
            let src = try writeTemp(named: "same.pdf", data: data)
            let link = tempURL(named: "same-link.pdf")
            defer {
                try? FileManager.default.removeItem(at: src)
                try? FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
            for dest in [src, link] {
                do {
                    try PDFSanitizer.process(from: src, to: dest, options: .default)
                    expect(false, "should throw for \(dest.lastPathComponent)")
                } catch let e as PDFSanitizerError {
                    if case .cannotWrite = e {
                        expect(true, "cannotWrite for \(dest.lastPathComponent)")
                    } else {
                        expect(false, "got \(e)")
                    }
                }
                expect(sha256(try Data(contentsOf: src)) == sha256(data), "source bytes unchanged")
            }
        } catch {
            expect(false, "\(error)")
        }
    }
}
