import Foundation
import PDFKit

extension CleardropTests {
    // MARK: - Helpers

    /// Expect `sanitize` to throw an error for which `matches` is true.
    static func expectRefusal(
        _ data: Data,
        _ what: String,
        _ matches: (PDFSanitizerError) -> Bool
    ) {
        do {
            _ = try PDFSanitizer.sanitize(data: data, options: .default)
            expect(false, "\(what): should be refused")
        } catch let e as PDFSanitizerError {
            expect(matches(e), "\(what): refused with \(e)")
        } catch {
            expect(false, "\(what): threw \(error)")
        }
    }

    static func isCorrupt(_ e: PDFSanitizerError) -> Bool {
        if case .corrupt = e { return true }
        return false
    }

    static func isUnsupported(_ e: PDFSanitizerError) -> Bool {
        if case .unsupportedStructure = e { return true }
        return false
    }

    /// The full set of checks for a file Cleardrop claims to clean.
    static func checkCleans(_ file: FixtureGenerator.CorpusFile) -> Bool {
        let before = (passes, failures)
        let name = file.name
        do {
            let data = file.data
            expectEqual(pdfKitPageCount(data), Optional(file.pages), "\(name): fixture opens in PDFKit")

            let info = try PDFSanitizer.inspect(data: data)
            expectEqual(info.pageCount, file.pages, "\(name): inspect page count")
            expect(info.findings.contains { $0.label == "Author" && $0.value == plantedAuthor }, "\(name): inspect shows the planted author")

            let source = try PDFParser.parse(data)
            let out = try PDFSanitizer.sanitize(data: data, options: .default)

            expectEqual(pdfKitPageCount(out), Optional(file.pages), "\(name): output page count")
            let text = pdfKitText(out)
            for expected in file.texts {
                expect(text.contains(expected), "\(name): text \"\(expected)\" survives")
            }
            expect(!contains(out, "PLANTED_"), "\(name): no planted token in output")
            expect(!contains(out, knownID_A), "\(name): trailer ID replaced")
            expect(!contains(out, "pdfTeX"), "\(name): no producer string")

            // The output is a single classic table with nothing left of the stream structure.
            expect(contains(out, "\nxref\n"), "\(name): classic table written")
            expect(!contains(out, "/ObjStm"), "\(name): no object stream")
            expect(!contains(out, "/XRef"), "\(name): no cross-reference stream")
            expect(!contains(out, "/Prev"), "\(name): single section")
            expect(!contains(out, "/Linearized"), "\(name): no linearization dictionary")

            // Level 0 leaves page content bytes alone.
            let cleaned = try PDFParser.parse(out)
            let contentBefore = contentOnlyPayloads(source)
            let contentAfter = contentOnlyPayloads(cleaned)
            for (number, payload) in contentBefore where cleaned.objects[number] != nil {
                expect(contentAfter[number] == payload, "\(name): stream \(number) bytes unchanged")
            }
            expect(!contentAfter.isEmpty, "\(name): content streams present")
            expectEqual(Set(cleaned.objects.keys), PDFReachability.reachableObjects(in: cleaned), "\(name): only reachable objects written")

            for i in 0..<file.pages {
                guard let a = renderPageBitmap(data, pageIndex: i, scale: 1.0),
                      let b = renderPageBitmap(out, pageIndex: i, scale: 1.0)
                else {
                    expect(false, "\(name) p\(i): render")
                    continue
                }
                expectEqual(maxChannelDelta(a, b), 0, "\(name) p\(i): pixel delta")
            }

            // Cleaning the output again must also work: the writer's files are readable.
            let again = try PDFSanitizer.sanitize(data: out, options: .default)
            expectEqual(pdfKitPageCount(again), Optional(file.pages), "\(name): cleaned output can be cleaned again")
        } catch {
            expect(false, "\(name): \(error) — \((error as? LocalizedError)?.errorDescription ?? "")")
        }
        return failures == before.1
    }

    // MARK: - Corpus

    static func testCorpusAllProfilesClean() {
        print("Generated corpus: every profile cleans")
        var results: [(String, Bool)] = []
        for file in FixtureGenerator.corpus {
            results.append((file.name, checkCleans(file)))
        }
        print("    corpus results:")
        for (name, ok) in results {
            print("      \(ok ? "pass" : "FAIL")  \(name)")
        }
        expectEqual(results.filter { !$0.1 }.count, 0, "profiles failing")
        expect(results.count >= 5, "corpus size \(results.count)")
    }

    static func testCorpusKeepsVersionHeader() {
        print("The PDF version in the header is kept")
        do {
            let v2 = try PDFSanitizer.sanitize(data: FixtureGenerator.modernGeneratorLike(version: "2.0").data, options: .default)
            expect(v2.starts(with: Data("%PDF-2.0".utf8)), "2.0 stays 2.0")
            let v16 = try PDFSanitizer.sanitize(data: FixtureGenerator.acrobatLike.data, options: .default)
            expect(v16.starts(with: Data("%PDF-1.6".utf8)), "1.6 stays 1.6")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testCorpusAllCompressionLevelsOpen() {
        print("Stream-structured files open at every compression level")
        for file in FixtureGenerator.corpus {
            for level in 0...4 {
                do {
                    let out = try PDFSanitizer.sanitize(
                        data: file.data, options: .default,
                        compression: CompressionProfiles.profile(for: level)
                    )
                    expectEqual(pdfKitPageCount(out), Optional(file.pages), "\(file.name) L\(level): pages")
                } catch {
                    expect(false, "\(file.name) L\(level): \(error)")
                }
            }
        }
    }

    static func testHybridXRefStmObjectsFound() {
        print("Hybrid file: objects listed only in /XRefStm are found")
        do {
            let data = FixtureGenerator.hybridLike.data
            expect(contains(data, "/XRefStm"), "fixture is hybrid")
            let graph = try PDFParser.parse(data)
            expect(graph.objects[2] != nil, "page tree (free in the table, present in the stream) loaded")
            expectEqual(PDFGraphInspect.pageCount(graph), 1, "one page")
            expect(graph.trailer["XRefStm"] == nil, "/XRefStm not carried into the graph")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testIndirectLengthInsideObjectStream() {
        print("A stream /Length stored inside an object stream is resolved")
        do {
            let file = FixtureGenerator.modernGeneratorLike()
            expect(contains(file.data, "/Length 10 0 R"), "fixture uses an indirect length")
            let out = try PDFSanitizer.sanitize(data: file.data, options: .default)
            expect(pdfKitText(out).contains("Modern page three"), "content read with the right length")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Refusals that must survive the new reader

    static func testEncryptedXRefStreamSaysEncrypted() {
        print("Encrypted file with a cross-reference stream reports encryption")
        let data = FixtureGenerator.pdfTeXLikeVariant(
            trailerExtra: "/Encrypt << /Filter /Standard /V 1 /R 2 /O (owner) /U (user) /P -4 >>"
        )
        expectRefusal(data, "sanitize") { $0 == .encrypted }
        do {
            let info = try PDFSanitizer.inspect(data: data)
            expect(info.isEncrypted, "inspect reports encrypted")
        } catch {
            expect(false, "inspect threw \(error)")
        }
        expectEqual(PDFSanitizerError.encrypted.errorDescription, "PDF is password-protected.", "message")
    }

    static func testSignedXRefStreamStillRefused() {
        print("Signed file with object streams is refused")
        let signature = Data("<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 1 2 3] /Contents <3080> >>".utf8)
        let data = FixtureGenerator.pdfTeXLikeVariant(extraObjects: [(30, signature)])
        expectRefusal(data, "signature dictionary inside an object stream") { $0 == .signed }
        do {
            expect(try PDFSanitizer.inspect(data: data).isSigned, "inspect reports signed")
        } catch {
            expect(false, "inspect threw \(error)")
        }
    }

    // MARK: - Damaged stream structure

    static func testTruncatedXRefStreamThrows() {
        print("Truncated cross-reference stream")
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.dropXRefRows = 3 }, "rows missing", isCorrupt)
        var cut = FixtureGenerator.pdfTeXLike.data
        if let marker = cut.range(of: Data("/Type /XRef".utf8)) {
            cut = cut.prefix(marker.upperBound + 60) + Data("\nendstream\nendobj\nstartxref\n\(FixtureGenerator.lastStartXRef(of: FixtureGenerator.pdfTeXLike.data))\n%%EOF\n".utf8)
        }
        expectRefusal(Data(cut), "stream cut short", isCorrupt)
    }

    static func testObjStmIndexPastEndThrows() {
        print("Object stream index past the end")
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.memberIndexShift = 50 }, "index beyond /N", isCorrupt)
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.memberIndexShift = 1 }, "index pointing at a different object", isCorrupt)
    }

    static func testObjStmContainingStreamThrows() {
        print("A stream stored inside an object stream")
        let body = Data("<< /Length 3 >>\nstream\nabc\nendstream".utf8)
        // Number 30 is forced into the object stream even though its body is a stream.
        let data = FixtureGenerator.pdfTeXLikeVariant(extraObjects: [(30, body)])
        expectRefusal(data, "stream member", isCorrupt)
    }

    static func testCompressedObjStmInObjStmThrows() {
        print("An object stream that is itself listed as compressed")
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.containerEntryCompressed = true }, "container entry is type 2", isCorrupt)
    }

    static func testInflateBombThrows() {
        print("Structural streams cannot inflate past the budget")
        let previous = PDFSanitizer.testMaxInflatedBytes
        PDFSanitizer.testMaxInflatedBytes = 256 * 1024
        defer { PDFSanitizer.testMaxInflatedBytes = previous }
        let bomb = FixtureGenerator.pdfTeXLikeVariant { $0.objectStreamPadding = 8 * 1024 * 1024 }
        expect(bomb.count < 64 * 1024, "8 MB of padding compresses to a small file (\(bomb.count) bytes)")
        expectRefusal(bomb, "object stream inflating to 8 MB with a 256 KB budget", isUnsupported)
        do {
            _ = try PDFSanitizer.sanitize(data: FixtureGenerator.pdfTeXLike.data, options: .default)
            expect(true, "the same file without padding fits the same budget")
        } catch {
            expect(false, "control without padding should pass: \(error)")
        }
    }

    static func testCyclicPrevAcrossStreamSections() {
        print("Cross-reference stream whose /Prev points at itself")
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.prevPointsAtItself = true }, "self /Prev", isCorrupt)
    }

    static func testAbsurdWWidthsThrow() {
        print("Unusable /W field widths")
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.widths = [1, 9, 1] }, "nine-byte field", isCorrupt)
        expectRefusal(FixtureGenerator.pdfTeXLikeVariant { $0.widths = [0, 0, 0] }, "all-zero widths", isCorrupt)
    }

    static func testUnsupportedStructuralFilterNamed() {
        print("A structural stream with a filter other than Flate is refused by name")
        var data = FixtureGenerator.pdfTeXLike.data
        // Relabel the cross-reference stream's filter without touching offsets.
        if let section = data.range(of: Data("/Type /XRef".utf8), options: .backwards),
           let filter = data.range(of: Data("/FlateDecode".utf8), options: .backwards, in: data.startIndex..<section.lowerBound)
        {
            data.replaceSubrange(filter, with: Data("/LZWDecode  ".utf8))
        }
        expectRefusal(data, "LZW cross-reference stream") { e in
            if case .unsupportedStructure(let reason) = e { return reason.contains("LZWDecode") }
            return false
        }
    }

    static func testStructuralStreamDecoderUnit() {
        print("PNG predictor rows decode back to the original bytes")
        let rows: [[UInt8]] = [[1, 0, 16, 0], [1, 0, 99, 0], [2, 0, 7, 3], [0, 0, 0, 255]]
        do {
            let filtered = FixtureGenerator.pngUpFilter(rows: rows)
            let restored = try StructuralStream.undoPNGPredictor(filtered, rowBytes: 4, pixelBytes: 1)
            expect(restored == Data(rows.flatMap { $0 }), "Up filter round trip")

            // One row per filter type, checked against values worked out by hand.
            let mixed = Data([
                0, 10, 20, 30,        // None
                1, 5, 5, 5,           // Sub: 5, 10, 15
                2, 1, 1, 1,           // Up: 6, 11, 16
                3, 2, 2, 2,           // Average: 2+3=5, 2+(5+11)/2=10, 2+(10+16)/2=15
                4, 1, 1, 1,           // Paeth
            ])
            let decoded = [UInt8](try StructuralStream.undoPNGPredictor(mixed, rowBytes: 3, pixelBytes: 1))
            expect(Array(decoded[0..<3]) == [10, 20, 30], "None")
            expect(Array(decoded[3..<6]) == [5, 10, 15], "Sub")
            expect(Array(decoded[6..<9]) == [6, 11, 16], "Up")
            expect(Array(decoded[9..<12]) == [5, 10, 15], "Average")
            expect(Array(decoded[12..<15]) == [6, 11, 16], "Paeth")

            let inflated = try Inflate.inflate(FixtureGenerator.deflate(Data(repeating: 7, count: 100_000)), budget: InflateBudget(100_000))
            expect(inflated == Data(repeating: 7, count: 100_000), "inflate round trip at the exact budget")
        } catch {
            expect(false, "\(error)")
        }
        do {
            _ = try Inflate.inflate(FixtureGenerator.deflate(Data(repeating: 7, count: 100_000)), budget: InflateBudget(99_999))
            expect(false, "one byte over budget should throw")
        } catch {
            expect(true, "one byte over budget throws")
        }
        do {
            _ = try Inflate.inflate(FixtureGenerator.deflate(Data(repeating: 7, count: 100_000)).dropLast(4), budget: InflateBudget(1_000_000))
            expect(false, "truncated Flate should throw")
        } catch {
            expect(true, "truncated Flate throws")
        }
    }
}
