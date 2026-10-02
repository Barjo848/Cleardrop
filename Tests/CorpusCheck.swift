import Foundation
import PDFKit

/// `./scripts/corpus_check.sh <directory>`: run the engine over every PDF under a directory
/// and report what happened to each. Everything is done in memory; no file is written,
/// copied or modified.
extension CleardropTests {
    static func runCorpusCheck(directory: String) -> Int32 {
        let root = URL(fileURLWithPath: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("Not a directory: \(directory)")
            return 2
        }
        var files: [URL] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
                files.append(url)
            }
        }
        files.sort { $0.path < $1.path }
        print("Checking \(files.count) PDF files under \(root.path)\n")

        var counts: [String: Int] = [:]
        var notes: [(outcome: String, file: String)] = []
        var mismatches = 0

        for (index, url) in files.enumerated() {
            if index > 0, index % 25 == 0 {
                print("  … \(index) of \(files.count)")
            }
            let name = url.lastPathComponent
            let outcome: String
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let out = try PDFSanitizer.sanitize(data: data, options: .default)
                let before = PDFDocument(data: data)?.pageCount
                let after = PDFDocument(data: out)?.pageCount
                if let before, before > 0, after != before {
                    outcome = "MISMATCH: cleaned, but pages \(before) → \(after.map(String.init) ?? "unreadable")"
                    mismatches += 1
                } else {
                    outcome = "cleaned"
                }
            } catch let error as PDFSanitizerError {
                switch error {
                case .encrypted: outcome = "refused: encrypted"
                case .signed: outcome = "refused: signed"
                case .oversize: outcome = "refused: too large"
                case .notPDF, .emptyInput: outcome = "refused: not a PDF"
                case .unsupportedStructure(let reason): outcome = "unsupported: \(reason)"
                case .corrupt(let reason): outcome = "damaged: \(reason)"
                case .cannotRead: outcome = "could not read"
                case .cannotWrite: outcome = "could not write"
                }
            } catch {
                outcome = "could not read"
            }
            counts[outcome, default: 0] += 1
            if outcome != "cleaned" {
                notes.append((outcome, name))
            }
        }

        print("Outcome counts:")
        for (outcome, count) in counts.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            print(String(format: "  %5d  %@", count, outcome))
        }
        if !notes.isEmpty {
            print("\nFiles not cleaned:")
            for note in notes.sorted(by: { $0.outcome < $1.outcome || ($0.outcome == $1.outcome && $0.file < $1.file) }) {
                print("  \(note.outcome)  —  \(note.file)")
            }
        }
        return mismatches == 0 ? 0 : 1
    }
}
