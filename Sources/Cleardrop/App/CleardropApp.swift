import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Files the app has been asked to open from outside the window: File → Open, Finder's
/// Open With, or a drop on the Dock icon. The window picks them up from here.
final class OpenRequests: ObservableObject {
    static let shared = OpenRequests()
    @Published var pending: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRequests.shared.pending = urls
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CleardropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window: Cleardrop handles one file at a time.
        Window("Cleardrop", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: ContentView.defaultSize.width, height: ContentView.defaultSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Uninstall Cleardrop…") { launchUninstaller() }
            }
        }
    }

    /// The app is sandboxed and cannot remove itself, so removal is done by a separate
    /// program inside the bundle. It asks for confirmation before it does anything.
    private func launchUninstaller() {
        // From now on, and only from now on, a confirmation from the uninstaller makes the
        // app erase its own settings and quit. Nothing is erased if the person cancels there.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(UninstallPlan.confirmedNotification),
            object: nil, queue: .main
        ) { _ in
            if let identifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: identifier)
                UserDefaults.standard.synchronize()
            }
            UninstallPlan.eraseOwnData(sandboxHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            // Leave at once, so quitting does not write window state back.
            exit(0)
        }

        let helper = Bundle.main.bundleURL.appendingPathComponent(UninstallPlan.helperRelativePath)
        NSWorkspace.shared.openApplication(at: helper, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "The uninstaller could not be opened"
                alert.informativeText = "To remove Cleardrop yourself, quit it and drag Cleardrop from the Applications folder to the Trash."
                alert.runModal()
            }
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PDF to review. It will not be changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        OpenRequests.shared.pending = [url]
    }
}
