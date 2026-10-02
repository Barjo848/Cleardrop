import Foundation
import CryptoKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Test runner. `./scripts/run_tests.sh` runs everything;
/// `./scripts/run_tests.sh --only <substring>` runs the tests whose name contains the substring.
@main
struct CleardropTests {
    static var failures = 0
    static var passes = 0
    static var skips = 0

    // Planted tokens. They exist only in fixtures and must be absent from cleaned output.
    static let plantedAuthor = "PLANTED_AUTHOR_CLEARDROP_9f3a"
    static let plantedTitle = "PLANTED_TITLE_CLEARDROP_7c2b"
    static let plantedCreator = "PLANTED_CREATOR_CLEARDROP_aa01"
    static let plantedProducer = "PLANTED_PRODUCER_CLEARDROP_bb02"
    static let plantedXmpDocID = "PLANTED_XMP_DOCID_CLEARDROP_1122"
    static let plantedPiece = "PLANTED_PIECEINFO_CLEARDROP_5566"
    static let knownID_A = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let plantedAnnotAuthor = "PLANTED_ANNOT_AUTHOR_CLEARDROP_a101"
    static let plantedAnnotDate = "PLANTED_ANNOT_DATE_CLEARDROP_a202"
    static let plantedPageXMP = "PLANTED_PAGE_XMP_CLEARDROP_b303"
    static let plantedJPEGExif = "PLANTED_JPEG_EXIF_CLEARDROP_c404"
    static let plantedJPEGXMP = "PLANTED_JPEG_XMP_CLEARDROP_d505"

    static let allTests: [(name: String, run: () -> Void)] = [
        // Repository and harness
        ("testEngineHasNoUIImports", testEngineHasNoUIImports),
        ("testSuiteWritesOnlyToTemp", testSuiteWritesOnlyToTemp),
        ("testGeneratedPhotoFixtureProperties", testGeneratedPhotoFixtureProperties),

        // Parser: incremental files, damaged input, exact round trip
        ("testIncrementalPrevKeepsPages", testIncrementalPrevKeepsPages),
        ("testIncrementalNewestObjectWins", testIncrementalNewestObjectWins),
        ("testCyclicPrevThrows", testCyclicPrevThrows),
        ("testBadPrevOffsetThrows", testBadPrevOffsetThrows),
        ("testQuartzPhantomEntryAccepted", testQuartzPhantomEntryAccepted),
        ("testDeepNestingThrowsNotCrashes", testDeepNestingThrowsNotCrashes),
        ("testLyingLengthThrows", testLyingLengthThrows),
        ("testUnterminatedStringsThrow", testUnterminatedStringsThrow),
        ("testUnresolvablePagesThrows", testUnresolvablePagesThrows),
        ("testNameBytesRoundTrip", testNameBytesRoundTrip),
        ("testRealsNeverExponent", testRealsNeverExponent),
        ("testPageCountInvariantOnAllFixtures", testPageCountInvariantOnAllFixtures),

        // Reader: cross-reference streams, object streams, hybrid files
        ("testCorpusAllProfilesClean", testCorpusAllProfilesClean),
        ("testCorpusKeepsVersionHeader", testCorpusKeepsVersionHeader),
        ("testCorpusAllCompressionLevelsOpen", testCorpusAllCompressionLevelsOpen),
        ("testHybridXRefStmObjectsFound", testHybridXRefStmObjectsFound),
        ("testIndirectLengthInsideObjectStream", testIndirectLengthInsideObjectStream),
        ("testEncryptedXRefStreamSaysEncrypted", testEncryptedXRefStreamSaysEncrypted),
        ("testSignedXRefStreamStillRefused", testSignedXRefStreamStillRefused),
        ("testTruncatedXRefStreamThrows", testTruncatedXRefStreamThrows),
        ("testObjStmIndexPastEndThrows", testObjStmIndexPastEndThrows),
        ("testObjStmContainingStreamThrows", testObjStmContainingStreamThrows),
        ("testCompressedObjStmInObjStmThrows", testCompressedObjStmInObjStmThrows),
        ("testInflateBombThrows", testInflateBombThrows),
        ("testCyclicPrevAcrossStreamSections", testCyclicPrevAcrossStreamSections),
        ("testAbsurdWWidthsThrow", testAbsurdWWidthsThrow),
        ("testUnsupportedStructuralFilterNamed", testUnsupportedStructuralFilterNamed),
        ("testStructuralStreamDecoderUnit", testStructuralStreamDecoderUnit),

        // Interop with real tools (skipped when the tool is not installed)
        ("testInteropPdfTeX", testInteropPdfTeX),
        ("testInteropQpdfObjectStreams", testInteropQpdfObjectStreams),

        // Review: what stays, signatures, copy that matches the action
        ("testResidualFindingsListed", testResidualFindingsListed),
        ("testResidualsIgnoreUnreachable", testResidualsIgnoreUnreachable),
        ("testStandingNoteAndEmptyState", testStandingNoteAndEmptyState),
        ("testEmptySignatureFieldAccepted", testEmptySignatureFieldAccepted),
        ("testFilledSignatureRefused", testFilledSignatureRefused),
        ("testByteRangeAloneRefused", testByteRangeAloneRefused),
        ("testActionTitleMatchesAction", testActionTitleMatchesAction),
        ("testDoneReportMatchesOutput", testDoneReportMatchesOutput),
        ("testProcessReturnsReport", testProcessReturnsReport),
        ("testErrorMessagesDistinct", testErrorMessagesDistinct),

        // Strip completeness: only reachable objects are written
        ("testIndirectInfoStringGone", testIndirectInfoStringGone),
        ("testNestedInfoChildGone", testNestedInfoChildGone),
        ("testPagePieceInfoGone", testPagePieceInfoGone),
        ("testOrphanObjectNotWritten", testOrphanObjectNotWritten),
        ("testSharedObjectSurvivesStrip", testSharedObjectSurvivesStrip),
        ("testIdentityRewriteDoesNotSweep", testIdentityRewriteDoesNotSweep),
        ("testSweepKeepsEveryPageResource", testSweepKeepsEveryPageResource),
        ("testNoPlantedTokenSurvives", testNoPlantedTokenSurvives),

        // Refusals and document-level strip
        ("testErrorMessagesAreShort", testErrorMessagesAreShort),
        ("testRejectsEncryptedSanitize", testRejectsEncryptedSanitize),
        ("testRejectsSignedSanitize", testRejectsSignedSanitize),
        ("testStripsPlantedInfoAuthor", testStripsPlantedInfoAuthor),
        ("testStripsCatalogXMPDocumentLevel", testStripsCatalogXMPDocumentLevel),
        ("testDocumentLevelDoesNotRequirePageMetadataGone", testDocumentLevelDoesNotRequirePageMetadataGone),
        ("testRegeneratesTrailerID", testRegeneratesTrailerID),
        ("testNoQuartzProducerInjected", testNoQuartzProducerInjected),
        ("testOutputUsesCleanName", testOutputUsesCleanName),
        ("testSourceUnchangedAfterStrip", testSourceUnchangedAfterStrip),

        // Per-object strip
        ("testEmbeddedJPEGEXIFRemoved", testEmbeddedJPEGEXIFRemoved),
        ("testEmbeddedJPEGXMPRemoved", testEmbeddedJPEGXMPRemoved),
        ("testJPEGStillDecodableAfterScrub", testJPEGStillDecodableAfterScrub),
        ("testAnnotationAuthorStripped", testAnnotationAuthorStripped),
        ("testAnnotationDatesStripped", testAnnotationDatesStripped),
        ("testAnnotationContentsPreserved", testAnnotationContentsPreserved),
        ("testPageLevelMetadataRemoved", testPageLevelMetadataRemoved),
        ("testPageCountStillPreservedDeep", testPageCountStillPreservedDeep),
        ("testDocumentLevelStillHoldsUnderDeep", testDocumentLevelStillHoldsUnderDeep),
        ("testDefaultEnablesDeepFlags", testDefaultEnablesDeepFlags),
        ("testInspectResidualFlagsOnPageMetadata", testInspectResidualFlagsOnPageMetadata),
        ("testScrubJPEGUnit", testScrubJPEGUnit),

        // Robustness
        ("testRejectsOversize", testRejectsOversize),
        ("testRejectsTooManyObjects", testRejectsTooManyObjects),
        ("testLargePDFUnderBudget", testLargePDFUnderBudget),
        ("testCorruptTruncatedXref", testCorruptTruncatedXref),
        ("testCorruptNotPDFJunk", testCorruptNotPDFJunk),
        ("testCorruptMissingStartxref", testCorruptMissingStartxref),
        ("testEncryptedMessage", testEncryptedMessage),
        ("testSignedMessage", testSignedMessage),
        ("testUTF8FilenameStem", testUTF8FilenameStem),
        ("testOutputIsSeparateFile", testOutputIsSeparateFile),
        ("testFuzzTruncatedMutantsNoCrash", testFuzzTruncatedMutantsNoCrash),
        ("testProcessNoOutputOnFailure", testProcessNoOutputOnFailure),
        ("testEmptyInputMessage", testEmptyInputMessage),
        ("testOversizeMessage", testOversizeMessage),

        // Defaults, review, save
        ("testProductionDefaultIsFullStrip", testProductionDefaultIsFullStrip),
        ("testPlistIdentity", testPlistIdentity),
        ("testBuildFailsOnSignFailure", testBuildFailsOnSignFailure),
        ("testOpenURLRoutesToReview", testOpenURLRoutesToReview),
        ("testReadmeClaimsHaveGates", testReadmeClaimsHaveGates),
        ("testUninstallPlanListsOnlyCleardropItems", testUninstallPlanListsOnlyCleardropItems),
        ("testEraseOwnDataStaysInsideSandbox", testEraseOwnDataStaysInsideSandbox),
        ("testUninstallerIsWiredAndPackaged", testUninstallerIsWiredAndPackaged),
        ("testInspectFindingsIncludeAuthor", testInspectFindingsIncludeAuthor),
        ("testProcessToChosenURL", testProcessToChosenURL),
        ("testRefusesToOverwriteSource", testRefusesToOverwriteSource),

        // Compression profiles and size formatting
        ("testProfilesAreFiveDiscreteSteps", testProfilesAreFiveDiscreteSteps),
        ("testDefaultLevelIsNone", testDefaultLevelIsNone),
        ("testProfileClamp", testProfileClamp),
        ("testByteSizeFormat", testByteSizeFormat),
        ("testLevel0NotLossy", testLevel0NotLossy),
        ("testHigherLevelsMarkLossyOrReflatten", testHigherLevelsMarkLossyOrReflatten),

        // Inventory and heuristic estimates
        ("testInventorySumsNearFileSize", testInventorySumsNearFileSize),
        ("testEstimateMonotonicNonIncreasing", testEstimateMonotonicNonIncreasing),
        ("testTextHeavyPDFEstimateBarelyShrinks", testTextHeavyPDFEstimateBarelyShrinks),
        ("testImageHeavyPDFEstimateShrinksAtBalanced", testImageHeavyPDFEstimateShrinksAtBalanced),
        ("testEstimateNeverExceedsOriginalByMuch", testEstimateNeverExceedsOriginalByMuch),
        ("testTextHeavyNoteAppears", testTextHeavyNoteAppears),

        // Lossless level
        ("testLevel1NeverChangesRenderedPixels", testLevel1NeverChangesRenderedPixels),
        ("testLevel1ContentStreamsStillValid", testLevel1ContentStreamsStillValid),
        ("testLevel1SizeNotLargerThanLevel0PlusEpsilon", testLevel1SizeNotLargerThanLevel0PlusEpsilon),
        ("testLevel1StillStripsMetadata", testLevel1StillStripsMetadata),
        ("testZlibCompressShrinksOrNil", testZlibCompressShrinksOrNil),
        ("testLevel1DoesNotTouchJPEGPixels", testLevel1DoesNotTouchJPEGPixels),

        // Lossy image levels
        ("testLevel2DownsamplesLargePhotoXObject", testLevel2DownsamplesLargePhotoXObject),
        ("testLevel2TextPageRenderUnchanged", testLevel2TextPageRenderUnchanged),
        ("testLevel2ImagePageSizeDrops", testLevel2ImagePageSizeDrops),
        ("testLevel3StrongerThanLevel2", testLevel3StrongerThanLevel2),
        ("testLevel2PreservesPageCountAndFonts", testLevel2PreservesPageCountAndFonts),
        ("testLevel2StillStripsMetadata", testLevel2StillStripsMetadata),
        ("testSkipSMaskImages", testSkipSMaskImages),
        ("testLevel0StillPixelPerfectOnPhotoPDF", testLevel0StillPixelPerfectOnPhotoPDF),

        // Compression labels match behaviour
        ("testCMYKJPEGUntouched", testCMYKJPEGUntouched),
        ("testGrayJPEGStaysGray", testGrayJPEGStaysGray),
        ("testMislabelledJPEGUntouched", testMislabelledJPEGUntouched),
        ("testCalRGBAndDecodeSkipped", testCalRGBAndDecodeSkipped),
        ("testSMaskTargetSkipped", testSMaskTargetSkipped),
        ("testSmallImageNotDownsampled", testSmallImageNotDownsampled),
        ("testLargeImageCappedAtLabel", testLargeImageCappedAtLabel),
        ("testNoDpiInLabels", testNoDpiInLabels),
        ("testReadmeCompressionTableMatchesProfiles", testReadmeCompressionTableMatchesProfiles),
        ("testEligibilityCountMatchesExport", testEligibilityCountMatchesExport),
        ("testRecompressedJPEGHasNoMetadata", testRecompressedJPEGHasNoMetadata),

        // Estimate accuracy and naming
        ("testEstimateErrorBandOnFixtures", testEstimateErrorBandOnFixtures),
        ("testProbeExactMatchesActual", testProbeExactMatchesActual),
        ("testProbeSkippedWhenTooLarge", testProbeSkippedWhenTooLarge),
        ("testDebouncedProbeGenerationLogic", testDebouncedProbeGenerationLogic),
        ("testSaveNameIncludesProfile", testSaveNameIncludesProfile),

        // Compression limits
        ("testExportUnderMemoryCap", testExportUnderMemoryCap),
        ("testCompressLevelsAllOpenInPDFKit", testCompressLevelsAllOpenInPDFKit),
        ("testCompressDoesNotRasterizeTextSelection", testCompressDoesNotRasterizeTextSelection),
        ("testWorkingCopyProfilesExist", testWorkingCopyProfilesExist),

        // Fidelity
        ("testFidelityContentStreamsByteIdentical", testFidelityContentStreamsByteIdentical),
        ("testFidelitySharedFontAndPageCount", testFidelitySharedFontAndPageCount),
        ("testFidelityRenderedPagesPixelExact", testFidelityRenderedPagesPixelExact),
        ("testFidelityRichFixtureFullStrip", testFidelityRichFixtureFullStrip),
        ("testFidelityJPEGPixelsUnchangedAfterEXIFScrub", testFidelityJPEGPixelsUnchangedAfterEXIFScrub),
        ("testFidelityAnnotContentsAndGeometryPreserved", testFidelityAnnotContentsAndGeometryPreserved),
        ("testFidelityMediaBoxesPreserved", testFidelityMediaBoxesPreserved),
        ("testFidelityIdentityRewriteThenStrip", testFidelityIdentityRewriteThenStrip),
        ("testFidelityMultipage50RenderSample", testFidelityMultipage50RenderSample),
    ]

    static func main() {
        var only: String?
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--corpus") {
            guard i + 1 < args.count else {
                print("usage: --corpus <directory>")
                exit(2)
            }
            exit(runCorpusCheck(directory: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--only") {
            guard i + 1 < args.count else {
                print("usage: --only <substring of test name>")
                exit(2)
            }
            only = args[i + 1]
        }
        let selected = allTests.filter { test in
            guard let only else { return true }
            return test.name.localizedCaseInsensitiveContains(only)
        }
        guard !selected.isEmpty else {
            print("No test name contains \"\(only ?? "")\".")
            exit(2)
        }

        print("=== Cleardrop test suite ===\n")
        for test in selected {
            print("[\(test.name)]")
            test.run()
        }

        print("\n=== Results: \(passes) passed, \(failures) failed, \(skips) skipped ===")
        if failures > 0 { exit(1) }
        print("ALL TESTS PASSED")
    }

    // MARK: - Helpers

    static func expect(_ cond: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
        if cond {
            passes += 1
            print("  ✓ \(msg)")
        } else {
            failures += 1
            print("  ✗ FAIL \(msg)  (\(file):\(line))")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
        expect(a == b, "\(msg)  (got \(a), want \(b))")
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func fixture(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/\(name)")
    }

    static func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixture(name))
    }

    static func contains(_ data: Data, _ token: String) -> Bool {
        data.range(of: Data(token.utf8)) != nil
    }

    static func containsExifMarker(_ data: Data) -> Bool {
        data.range(of: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) != nil // Exif\0\0
    }

    static func pdfKitPageCount(_ data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A destination inside the temporary directory. Tests write nowhere else.
    static func tempURL(named: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(named)")
    }

    static func writeTemp(named: String, data: Data) throws -> URL {
        let url = tempURL(named: named)
        try data.write(to: url)
        return url
    }

    /// Extract first DCTDecode stream payload from a PDF via parse.
    static func firstJPEGPayload(from pdf: Data) throws -> Data? {
        let g = try PDFParser.parse(pdf)
        for (_, entry) in g.objects {
            guard case .stream(let dict, let data) = entry.value else { continue }
            if ImageMetadataStripper.isDCTDecode(dict) {
                return data
            }
        }
        return nil
    }

    // MARK: - Stream and render helpers

    /// Non-image, non-metadata stream payloads keyed by object number.
    static func contentOnlyPayloads(_ graph: PDFDocumentGraph) -> [Int: Data] {
        var map: [Int: Data] = [:]
        for (num, entry) in graph.objects {
            guard case .stream(let dict, let data) = entry.value else { continue }
            if case .name(let t) = dict["Type"], t == "Metadata" { continue }
            if case .name(let t) = dict["Type"], t == "XObject" {
                if case .name(let st) = dict["Subtype"], st == "Image" {
                    // compared separately for JPEG scrub cases
                    continue
                }
            }
            if case .name(let t) = dict["Type"], t == "XRef" { continue }
            if ImageMetadataStripper.isDCTDecode(dict) { continue }
            map[num] = data
        }
        return map
    }

    static func renderPageBitmap(_ data: Data, pageIndex: Int, scale: CGFloat = 2.0) -> Data? {
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: pageIndex)
        else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let w = Int(ceil(bounds.width * scale))
        let h = Int(ceil(bounds.height * scale))
        guard w > 0, h > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            // PDFKit draws bottom-up; match page media box
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.tiffRepresentation
    }

    static func maxChannelDelta(_ a: Data, _ b: Data) -> Int {
        guard let ra = NSBitmapImageRep(data: a), let rb = NSBitmapImageRep(data: b),
              ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh,
              let pa = ra.bitmapData, let pb = rb.bitmapData
        else {
            return a == b ? 0 : 255
        }
        let n = ra.bytesPerRow * ra.pixelsHigh
        var maxD = 0
        for i in 0..<n {
            let d = abs(Int(pa[i]) - Int(pb[i]))
            if d > maxD { maxD = d }
        }
        return maxD
    }

    static func decodeJPEGPixels(_ jpeg: Data) -> (Int, Int, [UInt8])? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let w = img.width
        let h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }
}
