import Foundation
import ImageIO

extension CleardropTests {
    // MARK: - Repository shape

    static func engineSources() -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent("Sources/Cleardrop/Engine")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
            }
    }

    static func testEngineHasNoUIImports() {
        print("Engine imports no UI framework and no PDFKit")
        let sources = engineSources()
        expect(sources.count >= 10, "engine sources found (\(sources.count))")
        let forbidden = ["SwiftUI", "AppKit", "PDFKit", "Quartz"]
        for (name, text) in sources {
            let imports = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
                .map { String($0.dropFirst("import ".count)) }
            let bad = imports.filter { forbidden.contains($0) }
            expect(bad.isEmpty, "\(name) imports \(bad.isEmpty ? "nothing forbidden" : bad.joined(separator: ", "))")
        }
    }

    static func testSuiteWritesOnlyToTemp() {
        print("Engine picks no output location; tests write only to the temporary directory")
        for (name, text) in engineSources() {
            let picksLocation = text.contains("downloadsDirectory")
                || text.contains("desktopDirectory")
                || text.contains("documentDirectory")
                || text.contains("NSHomeDirectory")
            expect(!picksLocation, "\(name) names no user directory")
        }
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let dest = tempURL(named: "probe.pdf").standardizedFileURL.path
        expect(dest.hasPrefix(temp), "test destinations live under the temporary directory")

        let testsDir = repoRoot.appendingPathComponent("Tests")
        let files = (try? FileManager.default.contentsOfDirectory(at: testsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "swift" && url.lastPathComponent != "RepoTests.swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            expect(!text.contains("downloadsDirectory"), "\(url.lastPathComponent) does not touch Downloads")
        }
    }

    // MARK: - Generated fixtures

    static func testGeneratedPhotoFixtureProperties() {
        print("Generated photo fixture has the properties the compression tests rely on")
        do {
            let pdf = FixtureGenerator.photoPDF
            expectEqual(pdfKitPageCount(pdf), 1, "one page")
            expect(contains(pdf, plantedAuthor), "planted author present")

            let graph = try PDFParser.parse(pdf)
            let images = graph.objects.values.compactMap { entry -> (dict: [String: PDFValue], data: Data)? in
                guard case .stream(let dict, let data) = entry.value,
                      ImageMetadataStripper.isDCTDecode(dict)
                else { return nil }
                return (dict, data)
            }
            expectEqual(images.count, 1, "one DCT image")
            guard let image = images.first else { return }
            expect(image.dict["Width"] == .int(FixtureGenerator.photoWidth), "width \(FixtureGenerator.photoWidth)")
            expect(image.dict["Height"] == .int(FixtureGenerator.photoHeight), "height \(FixtureGenerator.photoHeight)")
            expect(image.data.count > 1_000_000, "JPEG is large enough to dominate the file (\(image.data.count) bytes)")
            expect(image.data.range(of: Data([0xFF, 0xE1])) != nil, "APP1 segment present")
            expect(image.data.range(of: Data([0xFF, 0xED])) != nil, "APP13 segment present")
            expectEqual(try PDFSanitizer.inspect(data: pdf).jpegWithAppMetadataCount, 1, "inspection reports the JPEG metadata")

            guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                expect(false, "JPEG decodes")
                return
            }
            expectEqual(decoded.width, FixtureGenerator.photoWidth, "decoded width")
        } catch {
            expect(false, "\(error)")
        }
    }
}
