import Foundation

/// The uninstaller's rules: what it may remove, and that erasing the app's own settings
/// cannot reach the person's files.
extension CleardropTests {
    static func testUninstallPlanListsOnlyCleardropItems() {
        print("The uninstall plan is a fixed list of Cleardrop's own items")
        let home = URL(fileURLWithPath: "/Volumes/Test/people/example", isDirectory: true)
        let appURL = URL(fileURLWithPath: "/Applications/Cleardrop.app", isDirectory: true)
        guard let plan = UninstallPlan.make(appURL: appURL, home: home) else {
            expect(false, "plan for /Applications/Cleardrop.app")
            return
        }
        expectEqual(plan.app.url.path, "/Applications/Cleardrop.app", "app path")
        expectEqual(plan.sandboxFolder.url.path, home.path + "/Library/Containers/io.github.barjo848.Cleardrop", "sandbox folder")
        for item in plan.userData {
            expect(item.url.path.hasPrefix(home.path + "/Library/"), "\(item.url.lastPathComponent) is under the home Library")
            expect(item.url.path.contains(UninstallPlan.bundleIdentifier), "\(item.url.lastPathComponent) is named for Cleardrop")
        }
        expectEqual(plan.allItems.count, plan.userData.count + 1, "the app plus its data, nothing else")

        // Anything that is not Cleardrop.app is refused.
        for path in ["/Applications/Preview.app", "/Applications", "/Applications/Cleardrop.app/Contents", home.path + "/Documents", "/"] {
            expect(UninstallPlan.make(appURL: URL(fileURLWithPath: path), home: home) == nil, "no plan for \(path)")
        }

        // The helper finds its app only from its place inside the bundle.
        let helper = appURL.appendingPathComponent(UninstallPlan.helperRelativePath)
        expectEqual(UninstallPlan.appContaining(helper: helper)?.path, "/Applications/Cleardrop.app", "helper inside the bundle")
        expect(UninstallPlan.appContaining(helper: URL(fileURLWithPath: "/tmp/Cleardrop Uninstaller.app")) == nil, "a helper copied elsewhere finds no app")
        expect(UninstallPlan.appContaining(helper: URL(fileURLWithPath: home.path + "/Documents/Helpers/Cleardrop Uninstaller.app")) == nil, "a look-alike folder is not an app")

        let plist = NSDictionary(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist")) as? [String: Any]
        expectEqual(plist?["CFBundleIdentifier"] as? String, UninstallPlan.bundleIdentifier, "identifier matches Info.plist")
    }

    static func testEraseOwnDataStaysInsideSandbox() {
        print("Erasing settings removes only the app's own state")
        guard let work = makeWorkDirectory() else {
            expect(false, "work directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: work) }
        let manager = FileManager.default
        do {
            // The person's real folders, outside the sandbox home.
            let documents = work.appendingPathComponent("real/Documents")
            try manager.createDirectory(at: documents, withIntermediateDirectories: true)
            let personal = documents.appendingPathComponent("tax-return.pdf")
            try Data("personal".utf8).write(to: personal)

            // A sandbox home laid out the way macOS makes one.
            let sandbox = work.appendingPathComponent("sandbox")
            for folder in UninstallPlan.ownDataFolders {
                try manager.createDirectory(at: sandbox.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            try manager.createSymbolicLink(at: sandbox.appendingPathComponent("Documents"), withDestinationURL: documents)
            let preferences = sandbox.appendingPathComponent("Library/Preferences/io.github.barjo848.Cleardrop.plist")
            try Data("prefs".utf8).write(to: preferences)
            let savedState = sandbox.appendingPathComponent("Library/Saved Application State/io.github.barjo848.Cleardrop.savedState")
            try manager.createDirectory(at: savedState, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: savedState.appendingPathComponent("windows.plist"))
            // A link inside a listed folder that points at the real Documents.
            try manager.createSymbolicLink(at: sandbox.appendingPathComponent("Library/Caches/link-out"), withDestinationURL: documents)
            // Something in the sandbox home that is not in a listed folder.
            let other = sandbox.appendingPathComponent("Library/Other")
            try manager.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: other.appendingPathComponent("keep.txt"))

            let removed = UninstallPlan.eraseOwnData(sandboxHome: sandbox)
            expect(removed >= 3, "items removed (\(removed))")
            expect(!manager.fileExists(atPath: preferences.path), "preferences erased")
            expect(!manager.fileExists(atPath: savedState.path), "saved window state erased")
            expect((try? manager.destinationOfSymbolicLink(atPath: sandbox.appendingPathComponent("Library/Caches/link-out").path)) == nil, "the link in Caches is removed")

            expect(manager.fileExists(atPath: personal.path), "the file in the real Documents is untouched")
            expectEqual(try Data(contentsOf: personal), Data("personal".utf8), "and unchanged")
            expect((try? manager.destinationOfSymbolicLink(atPath: sandbox.appendingPathComponent("Documents").path)) != nil, "the Documents link itself is left alone")
            expect(manager.fileExists(atPath: other.appendingPathComponent("keep.txt").path), "folders not on the list are left alone")

            // A listed folder that is itself a link to somewhere else is not entered.
            let trap = work.appendingPathComponent("trap")
            try manager.createDirectory(at: trap, withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: trap.appendingPathComponent("tmp"), withDestinationURL: documents)
            UninstallPlan.eraseOwnData(sandboxHome: trap)
            expect(manager.fileExists(atPath: personal.path), "a listed folder that is a link is not followed")
        } catch {
            expect(false, "\(error)")
        }
    }

    static func testUninstallerIsWiredAndPackaged() {
        print("The uninstaller and installer are built the way the README says")
        let app = readRepoFile("Sources/Cleardrop/App/CleardropApp.swift")
        expect(app.contains("Uninstall Cleardrop…"), "menu item present")
        expect(app.contains("UninstallPlan.confirmedNotification"), "the app erases its settings only on the uninstaller's confirmation")
        let helper = readRepoFile("Sources/Cleardrop/Uninstaller/UninstallerApp.swift")
        expect(helper.contains("trashItem"), "the uninstaller moves things to the Trash")
        expect(!helper.contains("removeItem"), "the uninstaller erases nothing itself")
        expect(helper.contains("buttons: [\"Uninstall\", \"Cancel\"]"), "it asks before doing anything")

        let build = readRepoFile("scripts/build.sh")
        expect(build.contains("$CONTENTS/Helpers/Cleardrop Uninstaller.app"), "build.sh places the uninstaller in the bundle")
        let sign = readRepoFile("scripts/sign.sh")
        expect(sign.contains("codesign --force --options runtime --sign \"$IDENTITY\" \"$HELPER\""), "the uninstaller is signed without the sandbox")

        let package = readRepoFile("scripts/package.sh")
        expect(package.contains("<key>BundleIsRelocatable</key>\n\t\t<false/>"), "the installer never relocates onto another copy")
        expect(package.contains("cp \"$ROOT/LICENSE\""), "the installer shows the licence")
        expect(!package.contains("|| true"), "package.sh ignores no failure")
        let distribution = readRepoFile("Resources/Installer/distribution.xml")
        expect(distribution.contains("enable_currentUserHome=\"true\"") && distribution.contains("enable_localSystem=\"true\""), "offers all users or only me")
        expect(distribution.contains("<license file="), "licence page")
        expect(readRepoFile("Resources/Installer/postinstall").contains("/usr/bin/open"), "opens the app after installing")
        expect(readRepoFile("Resources/Installer/welcome.txt").contains("does not make a document anonymous"), "the installer repeats the honesty contract")

        let readme = readRepoFile("README.md")
        expect(readme.contains("./scripts/package.sh"), "README documents the installer")
        expect(readme.contains("Uninstall Cleardrop…"), "README documents uninstalling")
    }
}
