import Foundation
import PDFKit

/// Tests against PDFs written by real third-party tools. The tools are optional on a
/// developer's machine: without them the test is reported as skipped. CI sets
/// `CLEARDROP_REQUIRE_INTEROP=1`, which turns a skip into a failure.
/// The PDFs are produced in the temporary directory and never committed.
extension CleardropTests {
    static var interopRequired: Bool {
        ProcessInfo.processInfo.environment["CLEARDROP_REQUIRE_INTEROP"] == "1"
    }

    static func findTool(_ name: String) -> URL? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Report a missing tool. Returns true when the caller should stop.
    static func skipUnlessAvailable(_ tool: URL?, named name: String) -> Bool {
        guard tool == nil else { return false }
        if interopRequired {
            expect(false, "\(name) is required (CLEARDROP_REQUIRE_INTEROP=1) but was not found")
        } else {
            skips += 1
            print("  ⚠︎ SKIPPED: \(name) not found. Install it to run this test.")
        }
        return true
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    static func makeWorkDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleardrop-interop-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - pdfTeX

    static func testInteropPdfTeX() {
        print("Interop: a PDF written by pdfTeX")
        let tool = findTool("pdflatex")
        if skipUnlessAvailable(tool, named: "pdflatex") { return }
        guard let tool, let work = makeWorkDirectory() else {
            expect(false, "work directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: work) }

        let source = """
        \\documentclass{article}
        \\pdfinfo{/Author (\(plantedAuthor)) /Title (\(plantedTitle))}
        \\begin{document}
        Hello from pdfTeX. $e^{i\\pi}+1=0$.
        \\newpage
        Second page with a rule: \\rule{3cm}{1pt}
        \\end{document}
        """
        do {
            try Data(source.utf8).write(to: work.appendingPathComponent("sample.tex"))
            let status = run(tool, ["-interaction=batchmode", "-halt-on-error", "sample.tex"], in: work)
            expectEqual(status, 0, "pdflatex exit status")
            let data = try Data(contentsOf: work.appendingPathComponent("sample.pdf"))

            expect(contains(data, "/ObjStm"), "pdfTeX wrote an object stream")
            expect(contains(data, "/XRef"), "pdfTeX wrote a cross-reference stream")
            expect(contains(data, "pdfTeX"), "pdfTeX wrote its producer string")

            let info = try PDFSanitizer.inspect(data: data)
            expectEqual(info.pageCount, 2, "inspect page count")
            expect(info.author == plantedAuthor, "inspect shows the author")
            expect(info.findings.contains { $0.label == "Producer" }, "inspect shows the producer")

            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expectEqual(pdfKitPageCount(out), 2, "output pages")
            let text = pdfKitText(out)
            expect(text.contains("Hello from pdfTeX"), "page one text")
            expect(text.contains("Second page"), "page two text")
            expect(!contains(out, plantedAuthor), "author gone")
            expect(!contains(out, plantedTitle), "title gone")
            expect(!contains(out, "pdfTeX-"), "producer string gone")
            expect(!contains(out, "PTEX.Fullbanner"), "pdfTeX banner key gone")
            expect(!contains(out, "/ObjStm") && !contains(out, "/XRef"), "classic structure written")
            for i in 0..<2 {
                guard let a = renderPageBitmap(data, pageIndex: i, scale: 1.0),
                      let b = renderPageBitmap(out, pageIndex: i, scale: 1.0)
                else {
                    expect(false, "render page \(i)")
                    continue
                }
                expectEqual(maxChannelDelta(a, b), 0, "page \(i) pixel delta")
            }
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - qpdf

    static func testInteropQpdfObjectStreams() {
        print("Interop: a PDF rewritten by qpdf with object streams")
        let tool = findTool("qpdf")
        if skipUnlessAvailable(tool, named: "qpdf") { return }
        guard let tool, let work = makeWorkDirectory() else {
            expect(false, "work directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: work) }

        do {
            let original = FixtureGenerator.twoSectionPDF
            try original.write(to: work.appendingPathComponent("in.pdf"))
            // qpdf exits 3 for warnings; the input here is clean, so 0 is expected.
            let status = run(tool, ["--object-streams=generate", "in.pdf", "out.pdf"], in: work)
            expectEqual(status, 0, "qpdf exit status")
            let data = try Data(contentsOf: work.appendingPathComponent("out.pdf"))
            expect(contains(data, "/ObjStm"), "qpdf wrote an object stream")
            expect(contains(data, "/XRef"), "qpdf wrote a cross-reference stream")

            expectEqual(try PDFSanitizer.inspect(data: data).pageCount, 2, "inspect page count")
            let out = try PDFSanitizer.sanitize(data: data, options: .default)
            expectEqual(pdfKitPageCount(out), 2, "output pages")
            let text = pdfKitText(out)
            expect(text.contains("Hello") && text.contains("Second"), "text of both pages")
            expect(!contains(out, plantedAuthor), "author gone")
            expect(!contains(out, "/ObjStm") && !contains(out, "/XRef"), "classic structure written")
        } catch {
            expect(false, "\(error)")
        }
    }
}
