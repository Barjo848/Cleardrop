import Foundation

/// The parts of a release that can be checked without a person: bundle identity, signing
/// strictness, how files reach the window, and what the README is allowed to say.
extension CleardropTests {
    static func readRepoFile(_ path: String) -> String {
        (try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    // MARK: - Bundle

    static func testPlistIdentity() {
        print("Info.plist identity and version")
        let url = repoRoot.appendingPathComponent("Resources/Info.plist")
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else {
            expect(false, "Resources/Info.plist is readable")
            return
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? ""
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        expectEqual(version, "0.0.0", "marketing version")
        expectEqual(build, "1", "build number")
        expectEqual(identifier, "io.github.barjo848.Cleardrop", "bundle identifier")
        expect(!identifier.hasPrefix("ai.x."), "not the placeholder identifier")
        expect(readRepoFile("CHANGELOG.md").contains("## \(version)"), "the changelog has an entry for \(version)")

        let entitlements = NSDictionary(contentsOf: repoRoot.appendingPathComponent("Resources/Cleardrop.entitlements")) as? [String: Any] ?? [:]
        expectEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true, "sandbox entitlement")
        expectEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true, "user-selected file access")
        expectEqual(entitlements.count, 2, "no other entitlement, in particular no network access")
    }

    // MARK: - Signing

    static func testBuildFailsOnSignFailure() {
        print("A signing failure fails the build")
        let build = readRepoFile("scripts/build.sh")
        expect(build.contains("set -euo pipefail"), "build.sh stops on the first error")
        expect(build.contains("scripts/sign.sh"), "build.sh signs through sign.sh")
        expect(!build.contains("|| true"), "build.sh ignores no failure")
        let sign = readRepoFile("scripts/sign.sh")
        expect(sign.contains("--options runtime"), "hardened runtime requested")
        expect(sign.contains("--entitlements"), "entitlements applied")
        expect(sign.contains("codesign --verify --strict"), "signature verified")
        expect(!sign.contains("|| true"), "sign.sh ignores no failure")

        // Run sign.sh with a codesign that fails: it must exit non-zero.
        guard let work = makeWorkDirectory() else {
            expect(false, "work directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let fakeApp = work.appendingPathComponent("Fake.app")
            try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
            let bin = work.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let stub = bin.appendingPathComponent("codesign")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [repoRoot.appendingPathComponent("scripts/sign.sh").path, fakeApp.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            expect(process.terminationStatus != 0, "sign.sh exits \(process.terminationStatus) when codesign fails")
        } catch {
            expect(false, "\(error)")
        }
    }

    // MARK: - Opening files

    static func testOpenURLRoutesToReview() {
        print("A file offered from outside is taken unless one is being read or written")
        let pdf = URL(fileURLWithPath: "/tmp/sample.pdf")
        let other = URL(fileURLWithPath: "/tmp/second.pdf")
        let web = URL(string: "https://example.com/file.pdf")!

        let accepting: [ReviewPhase] = [.idle, .review, .done("a.pdf", "message"), .failed("message")]
        for phase in accepting {
            expect(phase.acceptsNewFile, "\(phase) accepts a new file")
            expect(OpenRouting.urlToReview(offered: [pdf, other], phase: phase) == pdf, "\(phase): takes the first file")
        }
        for phase in [ReviewPhase.inspecting, .working] {
            expect(!phase.acceptsNewFile, "\(phase) does not accept a new file")
            expect(OpenRouting.urlToReview(offered: [pdf], phase: phase) == nil, "\(phase): request ignored")
        }
        expect(OpenRouting.urlToReview(offered: [], phase: .idle) == nil, "nothing offered")
        expect(OpenRouting.urlToReview(offered: [web], phase: .idle) == nil, "a web address is not opened")
        expect(OpenRouting.urlToReview(offered: [web, pdf], phase: .idle) == pdf, "the first local file is taken")

        // The window wires all three entry points to the same routing.
        let app = readRepoFile("Sources/Cleardrop/App/CleardropApp.swift")
        expect(app.contains("func application(_ application: NSApplication, open urls: [URL])"), "Open With and Dock drops are handled")
        expect(app.contains("keyboardShortcut(\"o\""), "File → Open has ⌘O")
        let view = readRepoFile("Sources/Cleardrop/App/ContentView.swift")
        expect(view.contains("OpenRouting.urlToReview"), "the window uses the shared routing")
        let plist = readRepoFile("Resources/Info.plist")
        expect(plist.contains("com.adobe.pdf"), "the bundle declares that it opens PDFs")
    }

    // MARK: - README

    static func testReadmeClaimsHaveGates() {
        print("README states the claims that tests back, and none of the ones they do not")
        let readme = readRepoFile("README.md")
        expect(!readme.isEmpty, "README is readable")

        // Each sentence is backed by the tests named beside it.
        let claims: [(sentence: String, backedBy: String)] = [
            ("does **not** make a document anonymous", "the contract itself"),
            ("Only objects the document still references are written", "testOrphanObjectNotWritten, testSweepKeepsEveryPageResource"),
            ("streams, object streams, or a mix", "testCorpusAllProfilesClean"),
            ("real pdfTeX and qpdf output", "testInteropPdfTeX, testInteropQpdfObjectStreams"),
            ("Always writes a single classic cross-reference table", "testCorpusAllProfilesClean"),
            ("Encrypted and digitally signed PDFs are **refused**", "testEncryptedXRefStreamSaysEncrypted, testFilledSignatureRefused"),
            ("an empty signature field is not signed", "testEmptySignatureFieldAccepted"),
            ("what\nstays in the file", "testResidualFindingsListed"),
            ("With compression set to **None**, page content is written back byte for byte", "testFidelityContentStreamsByteIdentical, testCorpusAllProfilesClean"),
            ("Only RGB and gray JPEG images are re-encoded", "testCMYKJPEGUntouched, testCalRGBAndDecodeSkipped"),
            ("Cleardrop refuses to save over the file you dropped", "testRefusesToOverwriteSource"),
            ("makes no network connections", "testPlistIdentity (no network entitlement)"),
            ("Intel Macs are not built or tested", "the CI workflow"),
            ("it is not notarized", "scripts/sign.sh"),
        ]
        for claim in claims {
            expect(readme.contains(claim.sentence), "README says \"\(claim.sentence.replacingOccurrences(of: "\n", with: " "))\" — backed by \(claim.backedBy)")
        }

        let forbidden = [
            "fully anonymous", "untraceable", "all PDFs", "any PDF", "PDF/A", "universal binary",
            "lossless compression of images", "no quality loss", "redact",
        ]
        for phrase in forbidden {
            let allowed = phrase == "redact" ? readme.replacingOccurrences(of: "not** redaction", with: "") : readme
            expect(!allowed.lowercased().contains(phrase.lowercased()), "README does not say \"\(phrase)\"")
        }

        let workflow = readRepoFile(".github/workflows/ci.yml")
        expect(workflow.contains("./scripts/run_tests.sh"), "CI runs the documented test command")
        expect(workflow.contains("./scripts/build.sh"), "CI runs the documented build command")
        expect(readme.contains("./scripts/run_tests.sh") && readme.contains("./scripts/build.sh"), "README documents both commands")
        expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("LICENSE").path), "LICENSE present")
        expect(readRepoFile("LICENSE").hasPrefix("MIT License"), "MIT licence")
    }
}
