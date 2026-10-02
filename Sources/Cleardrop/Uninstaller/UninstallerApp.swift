import AppKit

/// A small separate program that removes Cleardrop. It is separate because Cleardrop itself
/// is sandboxed and cannot delete its own bundle. It moves things to the Trash; it erases
/// nothing itself, so removing the app can be undone until the Trash is emptied.
final class UninstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Uninstaller.run()
        NSApp.terminate(nil)
    }
}

@main
enum Uninstaller {
    private static let delegate = UninstallerDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        // A normal application run loop, so the dialogs behave like any other app's.
        app.run()
    }

    static func run() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let appURL = UninstallPlan.appContaining(helper: Bundle.main.bundleURL),
              let plan = UninstallPlan.make(appURL: appURL, home: home),
              Bundle(url: appURL)?.bundleIdentifier == UninstallPlan.bundleIdentifier
        else {
            show(
                title: "Cleardrop can’t be uninstalled from here",
                text: "This uninstaller only works from inside the Cleardrop app. Open Cleardrop and choose Cleardrop → Uninstall Cleardrop…, or drag Cleardrop to the Trash yourself.",
                buttons: ["OK"]
            )
            return
        }

        let hasReceipt = packageReceiptExists()
        var lines = [
            "• \(plan.app.description) (\(displayPath(plan.app.url))) is moved to the Trash.",
            "• Cleardrop’s settings are erased.",
        ]
        if hasReceipt {
            lines.append("• The installer’s record of this installation is removed. macOS will ask for an administrator password for this; you can skip it, and it does not affect reinstalling.")
        }

        let choice = show(
            title: "Uninstall Cleardrop?",
            text: "\(lines.joined(separator: "\n"))\n\nYour PDFs are not touched, including copies Cleardrop saved.",
            buttons: ["Uninstall", "Cancel"]
        )
        guard choice == .alertFirstButtonReturn else { return }

        // Cleardrop erases its own settings and quits when it hears this. Only it can:
        // macOS protects an app's sandbox folder from other programs, including this one.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(UninstallPlan.confirmedNotification),
            object: nil, userInfo: nil, deliverImmediately: true
        )
        waitForCleardropToQuit()

        var problems: [String] = []
        if !moveToTrash(plan.app.url) {
            problems.append("The app could not be moved to the Trash. Drag \(displayPath(plan.app.url)) to the Trash yourself.")
        }
        // Remove what macOS allows of the per-user data. Anything that was erased from the
        // inside and cannot be removed from the outside is reported, not hidden.
        var leftovers: [UninstallPlan.Item] = []
        for item in plan.userData where FileManager.default.fileExists(atPath: item.url.path) {
            if !moveToTrash(item.url) {
                leftovers.append(item)
            }
        }
        forgetHomeReceipt()
        if hasReceipt, !forgetPackageReceipt() {
            problems.append("The installer’s record was left in place (skipped or not permitted). It does not affect reinstalling.")
        }

        var text = problems.isEmpty
            ? "The app is in the Trash and its settings were erased. Empty the Trash to finish."
            : problems.joined(separator: "\n\n")
        if !leftovers.isEmpty {
            text += "\n\nmacOS keeps an emptied folder for the app that only you can remove:\n\n"
                + leftovers.map { "• \(displayPath($0.url))" }.joined(separator: "\n")
                + "\n\nIt holds no Cleardrop settings. A fresh install starts clean either way."
        }
        let buttons = leftovers.isEmpty ? ["OK"] : ["OK", "Show in Finder"]
        let result = show(
            title: problems.isEmpty ? "Cleardrop was uninstalled" : "Cleardrop was not completely removed",
            text: text,
            buttons: buttons
        )
        if result == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(leftovers.map(\.url))
        }
    }

    // MARK: - Steps

    static func moveToTrash(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// Give Cleardrop a moment to erase its settings and quit; then ask it to quit.
    static func waitForCleardropToQuit() {
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: UninstallPlan.bundleIdentifier)
        }
        func wait(seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !running().isEmpty {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        wait(seconds: 4)
        running().forEach { $0.terminate() }
        wait(seconds: 4)
    }

    @discardableResult
    static func pkgutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// A receipt from installing "for all users". Removing it needs an administrator.
    static func packageReceiptExists() -> Bool {
        pkgutil(["--pkg-info", UninstallPlan.packageIdentifier])
    }

    /// A receipt from installing "for me only" lives in the home folder and needs no password.
    static func forgetHomeReceipt() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if pkgutil(["--volume", home, "--pkg-info", UninstallPlan.packageIdentifier]) {
            pkgutil(["--volume", home, "--forget", UninstallPlan.packageIdentifier])
        }
    }

    /// Removing a receipt needs administrator rights. macOS shows its own password dialog;
    /// this program never sees the password.
    static func forgetPackageReceipt() -> Bool {
        let command = "/usr/sbin/pkgutil --forget \(UninstallPlan.packageIdentifier)"
        let script = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Presentation

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @discardableResult
    static func show(title: String, text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
