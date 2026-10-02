import Foundation

/// Everything Cleardrop puts on a Mac, and nothing else. The uninstaller removes exactly
/// this list; it never searches for files or follows patterns.
struct UninstallPlan: Equatable {
    static let bundleIdentifier = "io.github.barjo848.Cleardrop"
    /// Identifier of the installer package's receipt.
    static let packageIdentifier = "io.github.barjo848.Cleardrop.pkg"
    /// Where the uninstaller lives inside the app bundle.
    static let helperRelativePath = "Contents/Helpers/Cleardrop Uninstaller.app"
    /// Posted by the uninstaller once the person has confirmed. Cleardrop listens for it only
    /// after it has opened the uninstaller itself, then erases its own settings and quits.
    static let confirmedNotification = "io.github.barjo848.Cleardrop.uninstallConfirmed"

    struct Item: Equatable {
        var url: URL
        /// What this is, in words the confirmation dialog can show.
        var description: String
    }

    /// The app bundle itself.
    var app: Item
    /// Per-user data macOS keeps for the app. Only those that exist need removing.
    /// The first entry is the sandbox folder, which macOS may not let another program remove.
    var userData: [Item]

    var sandboxFolder: Item { userData[0] }

    var allItems: [Item] { [app] + userData }

    /// - Parameters:
    ///   - appURL: the Cleardrop.app to remove.
    ///   - home: the user's real home directory.
    /// - Returns: `nil` unless `appURL` is an app bundle named Cleardrop.app. The caller must
    ///   also confirm its bundle identifier before removing anything.
    static func make(appURL: URL, home: URL) -> UninstallPlan? {
        let app = appURL.standardizedFileURL
        guard app.pathExtension == "app", app.lastPathComponent == "Cleardrop.app" else { return nil }

        let library = home.appendingPathComponent("Library", isDirectory: true)
        let id = bundleIdentifier
        let userData: [Item] = [
            Item(url: library.appendingPathComponent("Containers/\(id)", isDirectory: true),
                 description: "Settings and sandbox data"),
            Item(url: library.appendingPathComponent("Application Scripts/\(id)", isDirectory: true),
                 description: "Sandbox scripts folder"),
            Item(url: library.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true),
                 description: "Saved window state"),
            Item(url: library.appendingPathComponent("Preferences/\(id).plist"),
                 description: "Preferences"),
            Item(url: library.appendingPathComponent("Caches/\(id)", isDirectory: true),
                 description: "Caches"),
            Item(url: library.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true),
                 description: "Web storage"),
        ]
        return UninstallPlan(app: Item(url: app, description: "The Cleardrop app"), userData: userData)
    }

    /// Folders inside the app's own sandbox home where macOS keeps its state.
    static let ownDataFolders = [
        "Library/Preferences",
        "Library/Saved Application State",
        "Library/Caches",
        "Library/HTTPStorages",
        "Library/WebKit",
        "Library/Application Support",
        "tmp",
    ]

    /// Erase the app's own state from inside its sandbox. macOS protects a sandbox folder
    /// from other programs, so the app clears it itself; what is left is an empty shell.
    ///
    /// Only the contents of `ownDataFolders` are removed. A sandbox home also holds links to
    /// the person's real Desktop, Documents and Downloads; those are never listed here, and a
    /// link found inside a listed folder is removed as a link, never followed.
    /// - Returns: how many items were removed.
    @discardableResult
    static func eraseOwnData(sandboxHome: URL) -> Int {
        let manager = FileManager.default
        var removed = 0
        for folder in ownDataFolders {
            let directory = sandboxHome.appendingPathComponent(folder, isDirectory: true)
            // The folder itself must be a real directory inside the sandbox home.
            guard let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for child in children where (try? manager.removeItem(at: child)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// The app that contains a helper located at `helperURL`, if the helper is where
    /// Cleardrop keeps it.
    static func appContaining(helper helperURL: URL) -> URL? {
        let helper = helperURL.standardizedFileURL
        let components = helperRelativePath.split(separator: "/").map(String.init)
        var url = helper
        for expected in components.reversed() {
            guard url.lastPathComponent == expected else { return nil }
            url = url.deletingLastPathComponent()
        }
        return url.pathExtension == "app" ? url : nil
    }
}
