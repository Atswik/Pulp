import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - Shared chrome

/// One hairline-bordered, softly rounded surface used by every content pane,
/// so the page image, the editor and the previews all share the same edge.
private extension View {
    func paneSurface() -> some View {
        clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
                    .allowsHitTesting(false)
            }
    }
}

/// Title row for a pane. Actions on the right are icon-only and borderless
/// (their Labels still drive VoiceOver and, with `.help`, tooltips).
struct PaneHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            HStack(spacing: 2) { trailing }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

// MARK: - AppKit-backed views

struct PageImageView: NSViewRepresentable {
    var image: CGImage?
    @Binding var selection: CGRect?
    func makeNSView(context: Context) -> CropCanvas { CropCanvas() }
    func updateNSView(_ view: CropCanvas, context: Context) {
        view.image = image; view.selection = selection
        view.changed = { selection = $0 }; view.needsDisplay = true
    }
}

final class CropCanvas: NSView {
    var image: CGImage?
    var selection: CGRect?
    var changed: ((CGRect?) -> Void)?
    private var start: NSPoint?
    override var isFlipped: Bool { true }
    private var imageRect: CGRect {
        guard let image else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        guard let image else { return }
        NSImage(cgImage: image, size: imageRect.size).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let selection {
            let rect = CGRect(x: imageRect.minX + selection.minX * imageRect.width, y: imageRect.minY + selection.minY * imageRect.height, width: selection.width * imageRect.width, height: selection.height * imageRect.height)
            // Follows the user's system accent color instead of a fixed blue.
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); rect.fill()
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func mouseUp(with event: NSEvent) { update(event); start = nil }
    private func update(_ event: NSEvent) {
        guard let start, imageRect.width > 0, imageRect.height > 0 else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)).intersection(imageRect)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { changed?(nil); return }
        changed?(CGRect(x: (rect.minX-imageRect.minX)/imageRect.width, y: (rect.minY-imageRect.minY)/imageRect.height, width: rect.width/imageRect.width, height: rect.height/imageRect.height))
    }
}

struct DraftEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var insertMarker: String?
    @Binding var selectedRange: NSRange?
    var markerPageID: UUID?
    var pageID: UUID
    var editable: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        // The border now comes from `paneSurface()` so all panes match.
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let view = NSTextView(); view.isRichText = false; view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.delegate = context.coordinator; view.allowsUndo = true
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        view.isEditable = editable
        if view.string != text { view.string = text }
        if let marker = insertMarker, markerPageID == pageID, context.coordinator.lastMarker != marker {
            context.coordinator.lastMarker = marker
            DispatchQueue.main.async {
                view.insertText("\n\(marker)\n", replacementRange: view.selectedRange())
                context.coordinator.parent.text = view.string
                context.coordinator.parent.insertMarker = nil
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftEditor
        var lastMarker: String?
        init(_ parent: DraftEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string; parent.selectedRange = nil }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            parent.selectedRange = range.length > 0 ? range : nil
        }
    }
}

struct DraftPreview: NSViewRepresentable {
    let page: DraftPage
    @Binding var error: String
    var onRendered: ((UUID, Int, Double) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(); view.navigationDelegate = context.coordinator; return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        do {
            let html = try DocumentHTML.make(pages: [page])
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                context.coordinator.renderStart = .now
                context.coordinator.renderedPageID = page.id
                context.coordinator.renderedRevision = page.revision
                context.coordinator.navigation = view.loadHTMLString(html, baseURL: Bundle.module.resourceURL?.appendingPathComponent("Resources"))
            }
        } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DraftPreview
        var lastHTML = ""
        var renderStart: ContinuousClock.Instant?
        var renderedPageID: UUID?
        var renderedRevision = 0
        var navigation: WKNavigation?
        init(_ parent: DraftPreview) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            if let start = renderStart, let id = renderedPageID {
                parent.onRendered?(id, renderedRevision, PerformanceClock.seconds(since: start))
                renderStart = nil
            }
            webView.evaluateJavaScript("window.renderErrors.join('\\n')") { [weak self] result, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let failed = !(result as? String ?? "").isEmpty
                    let repaired = DocumentHTML.repairMathDelimiters(self.parent.page.text).needsReview
                    self.parent.error = failed || repaired ? "Some math may be incomplete or could not be displayed. Compare it with the original; you can select the original as a figure." : ""
                }
            }
        }
    }
}

// MARK: - Main window

@MainActor
final class CloseConfirmationDelegate: NSObject, NSWindowDelegate {
    weak var original: (any NSWindowDelegate)?
    let workspace: Workspace

    init(workspace: Workspace) { self.workspace = workspace }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        guard workspace.confirmDiscard() else { return false }
        workspace.dirty = false
        return true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

private struct WindowCloseConfirmation: NSViewRepresentable {
    let workspace: Workspace
    func makeCoordinator() -> CloseConfirmationDelegate { CloseConfirmationDelegate(workspace: workspace) }
    func makeNSView(context: Context) -> Probe { Probe(delegate: context.coordinator) }
    func updateNSView(_ view: Probe, context: Context) { view.install() }

    final class Probe: NSView {
        let closeDelegate: CloseConfirmationDelegate
        init(delegate: CloseConfirmationDelegate) { closeDelegate = delegate; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            guard let window, window.delegate !== closeDelegate else { return }
            closeDelegate.original = window.delegate
            window.delegate = closeDelegate
        }
    }
}

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    init(workspace: Workspace) { self.workspace = workspace; self.model = workspace.model }

    private func draftBinding(index: Int) -> Binding<String> {
        let pageID = workspace.pages[index].id
        return Binding(get: { workspace.pages.indices.contains(index) && workspace.pages[index].id == pageID ? workspace.pages[index].text : "" }, set: { newValue in
            guard workspace.pages.indices.contains(index), workspace.pages[index].id == pageID, workspace.pages[index].text != newValue else { return }
            workspace.pages[index].text = newValue; workspace.pages[index].revision += 1; workspace.dirty = true
        })
    }

    // MARK: Derived state

    /// Only call when `workspace.pages` is not empty.
    private var currentPage: DraftPage { workspace.pages[workspace.selectedPage] }
    private var convertedCount: Int {
        workspace.pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
    private var hasUnconvertedPages: Bool {
        workspace.pages.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var pageSubtitle: String {
        guard !workspace.pages.isEmpty else { return "" }
        let base = "Page \(workspace.selectedPage + 1) of \(workspace.pages.count)"
        let status = currentPage.status
        // The repeated-paragraph warning gets its own callout in the content area.
        if status.isEmpty || status.hasPrefix("Possible repeated paragraphs") { return base }
        return "\(base) · \(status)"
    }

    // MARK: Actions

    private func openPDF() {
        if workspace.open() { Task { await workspace.recognizeAll() } }
    }
    private func step(_ delta: Int) {
        workspace.selectedPage += delta; workspace.selection = nil; workspace.draftSelection = nil; workspace.dirty = true
    }

    // MARK: Body

    var body: some View {
        Group {
            if workspace.pages.isEmpty { emptyState } else { workArea }
        }
        .frame(minWidth: 850, minHeight: 600)
        .navigationSubtitle(pageSubtitle)
        .toolbar { toolbarItems }
        .background { WindowCloseConfirmation(workspace: workspace) }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .sheet(item: $workspace.correctionProposal) { proposal in
            CorrectionReview(workspace: workspace, proposal: proposal)
        }
    }

    // MARK: Toolbar (system chrome, secondary actions demoted into menus)

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { step(-1) } label: { Label("Previous Page", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(workspace.selectedPage == 0 || (workspace.processing && workspace.batchIndex == nil))
                .help("Previous Page")
            Button { step(1) } label: { Label("Next Page", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(workspace.selectedPage + 1 >= workspace.pages.count || (workspace.processing && workspace.batchIndex == nil))
                .help("Next Page")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openPDF() } label: { Label("Open PDF", systemImage: "doc.badge.plus") }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(workspace.processing)
                .help("Open PDF")
            Button { Task { await workspace.export() } } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace.pages.isEmpty || workspace.processing)
                .help("Export PDF")
            Menu {
                Button("Open Project") { workspace.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.processing)
                Divider()
                Button("Save Project") { workspace.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(workspace.document == nil || workspace.processing)
                Button("Save Project As…") { workspace.saveProject(asNew: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(workspace.document == nil || workspace.processing)
            } label: { Label("Project", systemImage: "folder") }
                .help("Project")
            if !model.ready && !model.hasDownloadedFiles {
                Menu {
                    Button("Download Model") { Task { await workspace.prepareModel() } }
                        .disabled(model.busy || workspace.processing)
                } label: { Label("OCR Model", systemImage: "cpu") }
                    .help("OCR Model")
            }
            // Restore this action in Settings when model management is added.
            // Button("Remove Model", role: .destructive) { model.remove() }
            //     .disabled(model.busy || workspace.processing)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Coverts your handwritten notes to typeset PDFs", systemImage: "doc.text")
        } description: {
            Text("First use downloads an OCR model (about 2.2 GB). Recognition and export run on your Mac.")
        } actions: {
            Button("Open PDF") { openPDF() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.processing)
            if !model.ready && !model.hasDownloadedFiles {
                Button("Download Model") { Task { await workspace.prepareModel() } }
                    .controlSize(.large)
                    .disabled(model.busy || workspace.processing)
            }
        }
    }

    // MARK: Work area

    private var workArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if currentPage.status.hasPrefix("Possible repeated paragraphs") {
                Label(currentPage.status, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            HSplitView {
                originalPane
                VSplitView {
                    draftPane
                    previewPane
                }.frame(minWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var originalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader("Original") {
                Button { workspace.addSelection() } label: { Label("Add Selected Figure", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(workspace.selection == nil || !workspace.canEditSelectedPage)
                    .help("Add Selected Figure")
                Button { workspace.addSelection(replaceDraft: true) } label: { Label("Replace with Original", systemImage: "photo.on.rectangle") }
                    .disabled(workspace.selection == nil || workspace.draftSelection == nil || !workspace.canEditSelectedPage)
                    .help("Replace with Original")
                if let undo = workspace.replacementUndo, workspace.pages[workspace.selectedPage].id == undo.pageID, workspace.pages[workspace.selectedPage].text == undo.after {
                    Button { workspace.undoReplacement() } label: { Label("Undo Replacement", systemImage: "arrow.uturn.backward") }
                        .disabled(!workspace.canEditSelectedPage)
                        .help("Undo Replacement")
                }
            }
            Text("Drag to select a figure or equation crop")
                .font(.caption)
                .foregroundStyle(.secondary)
            PageImageView(image: workspace.image(for: workspace.selectedPage), selection: $workspace.selection)
                .paneSurface()
        }
        .padding(12)
        .frame(minWidth: 320)
    }

    private var draftPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader("Edit text and LaTeX") {
                Button { Task { await workspace.recognize(workspace.selectedPage) } } label: { Label("Retry Page", systemImage: "arrow.clockwise") }
                    .disabled(workspace.processing)
                    .help("Retry Page")
                if currentPage.previousCorrection != nil {
                    Button { workspace.compareEarlierDraft() } label: { Label("Compare Recognition", systemImage: "rectangle.split.2x1") }
                        .disabled(workspace.processing)
                        .help("Compare Recognition")
                    Button { workspace.restoreBeforeCorrection() } label: { Label("Restore Earlier Draft", systemImage: "clock.arrow.circlepath") }
                        .disabled(workspace.processing)
                        .help("Restore Earlier Draft")
                }
            }
            if !workspace.canEditSelectedPage {
                Text("This page can be edited after conversion finishes.").font(.caption).foregroundStyle(.secondary)
            }
            DraftEditor(text: draftBinding(index: workspace.selectedPage), insertMarker: $workspace.markerToInsert, selectedRange: $workspace.draftSelection, markerPageID: workspace.markerPageID, pageID: workspace.pages[workspace.selectedPage].id, editable: workspace.canEditSelectedPage)
                .id(workspace.selectedPage)
                .paneSurface()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 160)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader("Rendered preview")
            if !workspace.mathError.isEmpty {
                Label(workspace.mathError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            DraftPreview(page: currentPage, error: $workspace.mathError) { id, revision, seconds in
                guard let index = workspace.pages.firstIndex(where: { $0.id == id }), workspace.pages[index].revision == revision else { return }
                workspace.pages[index].timings.previewSeconds = seconds
            }
            .paneSurface()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 160)
    }

    // MARK: Status bar (progress and messages live here, out of the way)

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            if let index = workspace.batchIndex {
                HStack(spacing: 10) {
                    Text(workspace.stopRequested ? "Finishing page \(index + 1) before stopping…" : "Converting page \(index + 1) of \(workspace.pages.count)")
                    ProgressView(value: Double(workspace.batchCompleted), total: Double(workspace.pages.count)).frame(width: 150)
                    Spacer()
                    Button("Stop & Save Project") { workspace.stopRequested = true }
                        .controlSize(.small)
                        .disabled(workspace.stopRequested)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            if workspace.showRemaining && !workspace.processing && hasUnconvertedPages {
                HStack(spacing: 10) {
                    Text("\(convertedCount) of \(workspace.pages.count) pages converted")
                    ProgressView(value: Double(convertedCount), total: Double(workspace.pages.count)).frame(width: 150)
                    Text("Some pages still need to be converted.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Convert Remaining Pages") { Task { await workspace.recognizeAll() } }
                        .controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            HStack(spacing: 10) {
                Text(model.status).lineLimit(1)
                if model.busy { ProgressView(value: model.progress).frame(width: 150) }
                Spacer()
                Text(workspace.message).lineLimit(1)
                if !workspace.pages.isEmpty {
                    TimingDetails(timings: currentPage.timings)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

/// Diagnostics are tucked into a popover instead of a permanent row.
struct TimingDetails: View {
    let timings: PageTimings
    @State private var shown = false
    private func value(_ seconds: Double?) -> String { seconds.map { String(format: "%.2f s", $0) } ?? "—" }
    var body: some View {
        Button { shown.toggle() } label: { Label("Page timings", systemImage: "stopwatch") }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Page timings")
            .popover(isPresented: $shown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Page timings").font(.headline)
                    Text("Page image: \(value(timings.pageRenderSeconds)) · OCR setup: \(value(timings.ocrSetupSeconds)) · OCR: \(value(timings.ocrRecognitionSeconds))")
                    Text("Preview: \(value(timings.previewSeconds))")
                    Text("The first OCR call also includes lazy model loading. Preview timing ends when the local page finishes loading.").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(14)
                .frame(width: 360, alignment: .leading)
            }
    }
}

// MARK: - Correction review sheet

struct CorrectionReview: View {
    @ObservedObject var workspace: Workspace
    let proposal: CorrectionProposal
    @State private var currentError = ""
    @State private var proposedError = ""

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(title)
            content().paneSurface()
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        let index = workspace.pages.firstIndex { $0.id == proposal.pageID } ?? workspace.selectedPage
        var current = workspace.pages[index]; current.text = proposal.original
        var proposed = workspace.pages[index]; proposed.text = proposal.proposed
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.isComparison ? "Compare recognition results" : "Compare the suggestion").font(.title2.weight(.semibold))
                Text("The model can change symbols, add text, or leave things out. Compare each part with the original before exporting.")
                    .foregroundStyle(.secondary)
            }
            if proposal.hasRenderingIssues {
                Label("This suggestion has incomplete math, repeated text, or unsupported formatting. Keep the current draft and try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 12) {
                column("Original page") {
                    PageImageView(image: workspace.image(for: index), selection: .constant(nil))
                }
                column(proposal.isComparison ? "Original recognition" : "Current draft") {
                    DraftPreview(page: current, error: $currentError)
                }
                column(proposal.isComparison ? "Current refined draft" : "Suggested draft") {
                    DraftPreview(page: proposed, error: $proposedError)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button(proposal.isComparison ? "Close" : "Keep Current Draft") { workspace.correctionProposal = nil }
                    .keyboardShortcut(.cancelAction)
                if !proposal.isComparison { Button("Try Again") { workspace.correctionProposal = nil; Task { await workspace.proposeCorrection() } } }
                Spacer()
                if !proposal.isComparison {
                    Button("Use Suggestion") { workspace.useCorrection(proposal) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(proposal.hasRenderingIssues)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 1100, minHeight: 650)
    }
}

#Preview("Pulp") {
    ContentView(workspace: Workspace())
}

// MARK: - App

@MainActor
final class NotesDelegate: NSObject, NSApplicationDelegate {
    static let workspace = Workspace()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.workspace.confirmDiscard() else { return .terminateCancel }
        Self.workspace.dirty = false
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PulpApp: App {
    @NSApplicationDelegateAdaptor(NotesDelegate.self) var delegate
    var body: some Scene { WindowGroup("Pulp") { ContentView(workspace: NotesDelegate.workspace) } }
}
