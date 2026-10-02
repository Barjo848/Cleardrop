import Foundation

/// Where the window is in its one-file-at-a-time flow. Kept in the engine so the rule for
/// when a new file may be taken is testable without the window.
enum ReviewPhase: Equatable, Sendable {
    case idle
    case inspecting
    case review
    case working
    /// Saved file name, and the engine's report of what the save did.
    case done(String, String)
    case failed(String)

    /// A file offered by drop, File → Open, Open With or the Dock is taken unless the app
    /// is in the middle of reading or writing one.
    var acceptsNewFile: Bool {
        switch self {
        case .idle, .review, .done, .failed: return true
        case .inspecting, .working: return false
        }
    }
}

enum OpenRouting {
    /// The first of the offered URLs that is a local file. Whether it is a PDF is decided by
    /// reading it, not by its name.
    static func firstOpenable(_ urls: [URL]) -> URL? {
        urls.first { $0.isFileURL }
    }

    /// What to do with files offered while in `phase`: the URL to start reviewing, or `nil`
    /// to ignore the request.
    static func urlToReview(offered urls: [URL], phase: ReviewPhase) -> URL? {
        guard phase.acceptsNewFile else { return nil }
        return firstOpenable(urls)
    }
}
