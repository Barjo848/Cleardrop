import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    /// Smallest window that fits the review screen. The window can be made larger.
    static let minimumSize = CGSize(width: 400, height: 600)
    /// Size the window opens at.
    static let defaultSize = CGSize(width: 440, height: 760)

    @ObservedObject private var openRequests = OpenRequests.shared
    @State private var phase: ReviewPhase = .idle
    @State private var isTargeted = false
    @State private var pendingURL: URL?
    @State private var pendingAccessed = false
    @State private var inspection: PDFInspection?
    @State private var sourceFileName: String = ""
    /// Discrete compression step 0...4
    @State private var compressionLevel: Double = Double(CompressionProfiles.defaultLevel)
    /// Live size estimate (heuristic immediately, probe when settled).
    @State private var liveEstimate: SizeEstimate?
    @State private var estimateGeneration: Int = 0
    @State private var isProbingEstimate: Bool = false

    private let outerPad: CGFloat = 20

    private var selectedProfile: CompressionProfile {
        CompressionProfiles.profile(for: Int(compressionLevel.rounded()))
    }

    private var workingTitle: String {
        selectedProfile.id >= 2 ? "Compressing PDF…"
            : selectedProfile.id == 1 ? "Packing PDF…"
            : "Cleaning PDF…"
    }

    private var workingSubtitle: String {
        switch selectedProfile.id {
        case 0:
            return "Stripping metadata, then saving where you choose."
        case 1:
            return "Stripping metadata and lossless stream packing."
        default:
            return "Stripping metadata and recompressing images."
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            dashedZone
                .padding(outerPad)
        }
        .frame(
            minWidth: Self.minimumSize.width, maxWidth: .infinity,
            minHeight: Self.minimumSize.height, maxHeight: .infinity
        )
        .onAppear {
            configureWindowChrome()
        }
        .onReceive(openRequests.$pending) { urls in
            guard !urls.isEmpty else { return }
            // Ignored while a file is being read or written; taken in any other state.
            if let url = OpenRouting.urlToReview(offered: urls, phase: phase) {
                reset()
                beginReview(url: url)
            }
            openRequests.pending = []
        }
        .onDisappear {
            stopAccessingPending()
        }
        .onChange(of: compressionLevel) { _, _ in
            guard phase == .review else { return }
            scheduleEstimateRefresh(probe: true)
        }
    }

    // MARK: - Chrome

    private var ink: Color { Color(white: 0.92) }
    private var dimInk: Color { ink.opacity(0.62) }
    private var faintInk: Color { ink.opacity(0.40) }
    private var accent: Color { Color(red: 0.35, green: 0.78, blue: 0.62) }

    private var dashedZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    borderStyle,
                    style: StrokeStyle(
                        lineWidth: isTargeted ? 2.5 : 1.25,
                        dash: phase == .idle && !isTargeted ? [6, 5] : []
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(zoneFill)
                )

            contentForPhase
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .animation(.easeInOut(duration: 0.22), value: phase)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private var borderStyle: Color {
        if isTargeted { return accent }
        switch phase {
        case .done: return accent.opacity(0.55)
        case .failed: return Color(white: 0.45)
        case .review: return Color(white: 0.38)
        default: return Color(white: 0.32)
        }
    }

    private var zoneFill: Color {
        if isTargeted {
            return accent.opacity(0.08)
        }
        return Color(white: 0.04)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var contentForPhase: some View {
        switch phase {
        case .idle:
            idleContent
        case .inspecting:
            statusContent(
                title: "Reading PDF…",
                subtitle: "Checking for hidden metadata."
            )
        case .review:
            reviewContent
        case .working:
            statusContent(
                title: workingTitle,
                subtitle: workingSubtitle
            )
        case .done(let name, let message):
            doneContent(name: name, message: message)
        case .failed(let msg):
            failedContent(message: msg)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "square.and.arrow.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(isTargeted ? accent : ink.opacity(0.85))
                .symbolRenderingMode(.hierarchical)

            Text(isTargeted ? "Release to inspect this PDF" : "Drop a PDF here")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(isTargeted ? accent : ink)
                .multilineTextAlignment(.center)

            Text("Drag a file from Finder onto this window, or choose File → Open.\nYou’ll see what will be removed and what stays, then choose where to save a copy.")
                .font(.system(size: 11.5, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusContent(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(ink)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Review — metadata list + clear

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceFileName)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                    if let inspection {
                        Text(ReviewSummary(inspection).summaryLine)
                            .font(.system(size: 11, weight: .regular, design: .default))
                            .foregroundStyle(dimInk)
                        Text("Size  \(ByteSizeFormat.string(bytes: inspection.fileSizeBytes))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.85))
                    }
                }
                Spacer(minLength: 8)
                Button("Cancel") { reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(faintInk)
            }

            Divider().background(Color(white: 0.22))

            if let inspection {
                if inspection.isSigned {
                    signedBanner
                } else {
                    let summary = ReviewSummary(inspection)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if summary.removable.isEmpty {
                                emptyFindingsBanner
                            } else {
                                sectionHeading(ReviewSummary.removableHeading)
                                ForEach(summary.removable) { finding in
                                    findingRow(finding)
                                }
                            }

                            sectionHeading(ReviewSummary.residualHeading)
                                .padding(.top, 4)
                            if summary.residual.isEmpty {
                                Text("Nothing else was detected that Cleardrop leaves in place.")
                                    .font(.system(size: 10.5, weight: .regular, design: .default))
                                    .foregroundStyle(faintInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(summary.residual) { finding in
                                findingRow(finding)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)

                    // Outside the scrolling list so it is on screen for every file.
                    if let residualLine = summary.residualLine {
                        Text(residualLine)
                            .font(.system(size: 10.5, weight: .semibold, design: .default))
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(ReviewSummary.standingNote)
                        .font(.system(size: 10.5, weight: .regular, design: .default))
                        .foregroundStyle(dimInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if inspection?.isSigned != true {
                compressionControls
            }

            Spacer(minLength: 4)

            if let inspection, !inspection.isSigned {
                Button(action: clearAndSave) {
                    Text(ReviewSummary(inspection).actionTitle(for: selectedProfile))
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(Color.black.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accent)
                        )
                }
                .buttonStyle(.plain)

                Text("You’ll pick the save location next. Your original file is never overwritten.")
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(faintInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if inspection?.isSigned == true {
                Button(action: reset) {
                    Text("Choose another PDF")
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(white: 0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Discrete compression control + heuristic / probed size estimate.
    private var compressionControls: some View {
        let profile = selectedProfile
        let estimate = liveEstimate

        return VStack(alignment: .leading, spacing: 8) {
            Text("COMPRESSION")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(faintInk)

            HStack(alignment: .firstTextBaseline) {
                Text(profile.name)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(ink)
                Spacer()
                if let inspection, let estimate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(resultSizeLine(originalBytes: inspection.fileSizeBytes, estimate: estimate))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(dimInk)
                        HStack(spacing: 6) {
                            if let savings = estimate.savingsLine(originalBytes: inspection.fileSizeBytes) {
                                Text(savings)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(accent.opacity(0.9))
                            }
                            if isProbingEstimate {
                                Text("Measuring…")
                                    .font(.system(size: 9, weight: .regular, design: .default))
                                    .foregroundStyle(faintInk)
                            } else {
                                Text(estimate.confidenceCaption())
                                    .font(.system(size: 9, weight: .regular, design: .default))
                                    .foregroundStyle(faintInk)
                            }
                        }
                    }
                }
            }

            Slider(
                value: $compressionLevel,
                in: Double(CompressionProfiles.minLevel)...Double(CompressionProfiles.maxLevel),
                step: 1
            )
            .tint(accent)

            HStack(spacing: 0) {
                ForEach(CompressionProfiles.all) { p in
                    Text(p.name)
                        .font(.system(size: 8, weight: p.id == profile.id ? .semibold : .regular, design: .default))
                        .foregroundStyle(p.id == profile.id ? ink : faintInk)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Text(profile.summary)
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(accent.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Text(profile.detail)
                .font(.system(size: 10, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)

            if let scope = inspection.flatMap({ ReviewSummary($0).compressionScopeNote(for: profile) }) {
                Text(scope)
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(faintInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if profile.isLossy {
                Text(CompressionProfiles.eligibilityNote)
                    .font(.system(size: 9, weight: .regular, design: .default))
                    .foregroundStyle(faintInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(faintInk)
    }

    private func resultSizeLine(originalBytes: Int, estimate: SizeEstimate) -> String {
        let original = ByteSizeFormat.string(bytes: originalBytes)
        return "\(original) → \(estimate.displayString())"
    }

    /// Immediate heuristic + optional debounced dry-run probe.
    private func scheduleEstimateRefresh(probe: Bool) {
        guard let inspection else {
            liveEstimate = nil
            return
        }
        let profile = selectedProfile
        liveEstimate = SizeEstimator.estimate(
            inventory: inspection.sizeInventory,
            profile: profile
        )

        guard probe,
              SizeEstimator.shouldProbe(fileSizeBytes: inspection.fileSizeBytes),
              let url = pendingURL
        else {
            isProbingEstimate = false
            return
        }

        estimateGeneration += 1
        let gen = estimateGeneration
        let level = profile.id
        isProbingEstimate = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000) // 280ms debounce
            guard gen == estimateGeneration, phase == .review else { return }

            let accessed = pendingAccessed
            let probed = await Task.detached(priority: .utility) {
                _ = accessed
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                    return nil as SizeEstimate?
                }
                return SizeEstimator.probe(
                    data: data,
                    options: .default,
                    profile: CompressionProfiles.profile(for: level)
                )
            }.value

            guard gen == estimateGeneration, phase == .review else { return }
            isProbingEstimate = false
            if let probed {
                liveEstimate = probed
            }
        }
    }

    private var signedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signed PDF")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(ink)
            Text("This file appears to be digitally signed. Cleardrop will not modify it, so the signature is never silently broken.")
                .font(.system(size: 11.5, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.08))
        )
    }

    private var emptyFindingsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ReviewSummary.emptyTitle)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(ink)
            Text(ReviewSummary.emptyBody)
                .font(.system(size: 11.5, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.08))
        )
    }

    private func findingRow(_ finding: MetadataFinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.label)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(ink)
            if let value = finding.value {
                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(dimInk)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Text(finding.category)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(faintInk)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.07))
        )
    }

    // MARK: Done / Failed

    private func doneContent(name: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(accent)

            Text("Saved")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(ink)

            Text(name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)

            Text(message)
                .font(.system(size: 11.5, weight: .regular, design: .default))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: reset) {
                Text("Again")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(Color.black.opacity(0.9))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(ink.opacity(0.85))

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(dimInk)
                .multilineTextAlignment(.center)

            Button(action: reset) {
                Text("Again")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(white: 0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func configureWindowChrome() {
        if let win = NSApp.windows.first {
            win.title = "Cleardrop"
            win.isMovableByWindowBackground = true
            win.backgroundColor = .black
            win.titlebarAppearsTransparent = true
        }
    }

    private func reset() {
        stopAccessingPending()
        pendingURL = nil
        inspection = nil
        sourceFileName = ""
        compressionLevel = Double(CompressionProfiles.defaultLevel)
        liveEstimate = nil
        estimateGeneration += 1
        isProbingEstimate = false
        phase = .idle
    }

    private func stopAccessingPending() {
        if pendingAccessed, let url = pendingURL {
            url.stopAccessingSecurityScopedResource()
        }
        pendingAccessed = false
    }

    private func beginReview(url: URL) {
        stopAccessingPending()
        pendingURL = url
        pendingAccessed = url.startAccessingSecurityScopedResource()
        sourceFileName = url.lastPathComponent
        phase = .inspecting

        Task { @MainActor in
            do {
                let accessed = pendingAccessed
                let result = try await Task.detached(priority: .userInitiated) {
                    // Access already started on main; read under same security scope.
                    _ = accessed
                    return try PDFSanitizer.inspect(url: url)
                }.value

                if result.isEncrypted {
                    phase = .failed(PDFSanitizerError.encrypted.errorDescription ?? "PDF is password-protected.")
                    stopAccessingPending()
                    pendingURL = nil
                    return
                }

                inspection = result
                compressionLevel = Double(CompressionProfiles.defaultLevel)
                phase = .review
                scheduleEstimateRefresh(probe: true)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                phase = .failed(msg)
                stopAccessingPending()
                pendingURL = nil
            }
        }
    }

    private func clearAndSave() {
        guard let source = pendingURL else {
            phase = .failed("No PDF loaded.")
            return
        }
        if inspection?.isSigned == true {
            phase = .failed(PDFSanitizerError.signed.errorDescription ?? "Signed PDFs are not modified.")
            return
        }

        let profile = selectedProfile

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.title = "Save cleaned PDF"
        panel.message = "Choose where to save the cleaned copy. Your original file will not be changed."
        panel.nameFieldStringValue = ExportNaming.suggestedFileName(
            original: source,
            profile: profile
        )
        // Suggest the original's folder; the name differs, so the original is not replaced.
        panel.directoryURL = source.deletingLastPathComponent()

        guard panel.runModal() == .OK, let dest = panel.url else {
            // User cancelled — stay on review
            return
        }

        phase = .working
        Task { @MainActor in
            do {
                let accessed = pendingAccessed
                let compression = profile
                let report = try await Task.detached(priority: .userInitiated) {
                    _ = accessed
                    return try PDFSanitizer.process(
                        from: source,
                        to: dest,
                        options: .default,
                        compression: compression
                    )
                }.value

                phase = .done(dest.lastPathComponent, report.message)
                NSSound.beep()
                stopAccessingPending()
                pendingURL = nil
                inspection = nil
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                phase = .failed(msg)
            }
        }
    }



    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard phase.acceptsNewFile else { return false }
        if phase != .idle { reset() }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        if let url = item as? URL { return url }
                        if let str = item as? String { return URL(fileURLWithPath: str) }
                        return nil
                    }()
                    guard let url else { return }
                    Task { @MainActor in
                        beginReview(url: url)
                    }
                }
                return true
            }
        }
        return false
    }
}
