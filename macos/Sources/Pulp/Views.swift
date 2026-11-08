import AppKit
import PDFKit
import SwiftUI
import WebKit

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
            NSColor.systemBlue.withAlphaComponent(0.15).setFill(); rect.fill()
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
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
    var markerPageID: UUID?
    var pageID: UUID
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let view = NSTextView(); view.isRichText = false; view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.delegate = context.coordinator
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
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
            if let view = notification.object as? NSTextView { parent.text = view.string }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open PDF") { if workspace.open() { Task { await workspace.recognizeAll() } } }.disabled(workspace.processing)
                Button("Recognize Remaining") { Task { await workspace.recognizeAll() } }.disabled(workspace.pages.isEmpty || workspace.processing)
                Button("Export PDF") { Task { await workspace.export() } }.disabled(workspace.pages.isEmpty || workspace.processing)
                Spacer()
                if !model.ready {
                    Button("Download Model") { Task { await model.prepare() } }.disabled(model.busy || workspace.processing)
                } else {
                    Button("Remove Model") { model.remove() }.disabled(model.busy || workspace.processing)
                }
            }
            HStack {
                Text(model.status).font(.caption)
                if model.busy { ProgressView(value: model.progress).frame(width: 150) }
                Spacer(); Text(workspace.message).font(.caption)
            }
            if workspace.pages.isEmpty {
                ContentUnavailableView("Open handwritten notes", systemImage: "doc.text", description: Text("Opening a PDF starts recognition. First use downloads an OCR model (about 2.2 GB). Recognition and export run on your Mac."))
            } else {
                HStack {
                    Button("Previous") { workspace.selectedPage -= 1; workspace.selection = nil }.disabled(workspace.selectedPage == 0 || workspace.processing)
                    Text("Page \(workspace.selectedPage + 1) of \(workspace.pages.count)")
                    Button("Next") { workspace.selectedPage += 1; workspace.selection = nil }.disabled(workspace.selectedPage + 1 >= workspace.pages.count || workspace.processing)
                    Button("Retry Page") { Task { await workspace.recognize(workspace.selectedPage) } }.disabled(workspace.processing)
                    if workspace.pages[workspace.selectedPage].previousCorrection != nil {
                        Button("Compare Recognition") { workspace.compareEarlierDraft() }.disabled(workspace.processing)
                        Button("Restore Earlier Draft") { workspace.restoreBeforeCorrection() }.disabled(workspace.processing)
                    }
                    Text(workspace.pages[workspace.selectedPage].status).font(.caption)
                    Spacer()
                    Button("Add Selected Figure") { workspace.addSelection() }.disabled(workspace.selection == nil || workspace.processing)
                }
                if workspace.pages[workspace.selectedPage].status.hasPrefix("Possible repeated paragraphs") {
                    Text(workspace.pages[workspace.selectedPage].status).foregroundStyle(.orange)
                }
                HSplitView {
                    VStack(alignment: .leading) {
                        Text("Original — drag to select a figure or equation crop").font(.headline)
                        PageImageView(image: workspace.image(for: workspace.selectedPage), selection: $workspace.selection)
                    }.frame(minWidth: 320)
                    VSplitView {
                        VStack(alignment: .leading) {
                            Text("Edit text and LaTeX").font(.headline)
                            DraftEditor(text: draftBinding(index: workspace.selectedPage), insertMarker: $workspace.markerToInsert, markerPageID: workspace.markerPageID, pageID: workspace.pages[workspace.selectedPage].id).id(workspace.selectedPage)
                        }.frame(minHeight: 160)
                        VStack(alignment: .leading) {
                            Text("Rendered preview").font(.headline)
                            if !workspace.mathError.isEmpty { Text(workspace.mathError).foregroundStyle(.red).font(.caption) }
                            DraftPreview(page: workspace.pages[workspace.selectedPage], error: $workspace.mathError) { id, revision, seconds in
                                guard let index = workspace.pages.firstIndex(where: { $0.id == id }), workspace.pages[index].revision == revision else { return }
                                workspace.pages[index].timings.previewSeconds = seconds
                            }
                        }.frame(minHeight: 160)
                    }.frame(minWidth: 360)
                }
                TimingDetails(timings: workspace.pages[workspace.selectedPage].timings)
            }
        }.padding().frame(minWidth: 850, minHeight: 600)
        .sheet(item: $workspace.correctionProposal) { proposal in
            CorrectionReview(workspace: workspace, proposal: proposal)
        }
    }
}

struct TimingDetails: View {
    let timings: PageTimings
    private func value(_ seconds: Double?) -> String { seconds.map { String(format: "%.2f s", $0) } ?? "—" }
    var body: some View {
        DisclosureGroup("Page timings") {
            VStack(alignment: .leading) {
                Text("Page image: \(value(timings.pageRenderSeconds)) · OCR setup: \(value(timings.ocrSetupSeconds)) · OCR: \(value(timings.ocrRecognitionSeconds))")
                Text("Preview: \(value(timings.previewSeconds))")
                Text("The first OCR call also includes lazy model loading. Preview timing ends when the local page finishes loading.").foregroundStyle(.secondary)
            }.font(.caption)
        }.font(.caption)
    }
}

struct CorrectionReview: View {
    @ObservedObject var workspace: Workspace
    let proposal: CorrectionProposal
    @State private var currentError = ""
    @State private var proposedError = ""

    var body: some View {
        let index = workspace.pages.firstIndex { $0.id == proposal.pageID } ?? workspace.selectedPage
        var current = workspace.pages[index]; current.text = proposal.original
        var proposed = workspace.pages[index]; proposed.text = proposal.proposed
        return VStack(alignment: .leading, spacing: 12) {
            Text(proposal.isComparison ? "Compare recognition results" : "Compare the suggestion").font(.title2)
            Text("The model can change symbols, add text, or leave things out. Compare each part with the original before exporting.")
            if proposal.hasRenderingIssues { Text("This suggestion has incomplete math, repeated text, or unsupported formatting. Keep the current draft and try again.").foregroundStyle(.red) }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Original page").font(.headline)
                    PageImageView(image: workspace.image(for: index), selection: .constant(nil))
                }
                VStack(alignment: .leading) {
                    Text(proposal.isComparison ? "Original recognition" : "Current draft").font(.headline)
                    DraftPreview(page: current, error: $currentError)
                }
                VStack(alignment: .leading) {
                    Text(proposal.isComparison ? "Current refined draft" : "Suggested draft").font(.headline)
                    DraftPreview(page: proposed, error: $proposedError)
                }
            }
            HStack {
                Button(proposal.isComparison ? "Close" : "Keep Current Draft") { workspace.correctionProposal = nil }
                if !proposal.isComparison { Button("Try Again") { workspace.correctionProposal = nil; Task { await workspace.proposeCorrection() } } }
                Spacer()
                if !proposal.isComparison { Button("Use Suggestion") { workspace.useCorrection(proposal) }.disabled(proposal.hasRenderingIssues) }
            }
        }.padding().frame(minWidth: 1100, minHeight: 650)
    }
}

@MainActor
final class NotesDelegate: NSObject, NSApplicationDelegate {
    static let workspace = Workspace()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.workspace.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PulpApp: App {
    @NSApplicationDelegateAdaptor(NotesDelegate.self) var delegate
    var body: some Scene { WindowGroup("Pulp") { ContentView(workspace: NotesDelegate.workspace) } }
}
