import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published var document: PDFDocument?
    @Published var pages: [DraftPage] = []
    @Published var selectedPage = 0
    @Published var selection: CGRect?
    @Published var markerToInsert: String?
    @Published var markerPageID: UUID?
    @Published var processing = false
    @Published var batchIndex: Int?
    @Published var batchCompleted = 0
    @Published var stopRequested = false
    @Published var showRemaining = false
    @Published var draftSelection: NSRange?
    @Published var replacementUndo: (pageID: UUID, before: String, after: String, figureID: UUID)?
    @Published var message = "Open a PDF to begin."
    @Published var dirty = false
    @Published var mathError = ""
    @Published var correctionProposal: CorrectionProposal?
    @Published var projectURL: URL?
    private var runningTimings: [UUID: PageTimings] = [:]
    private var idleUnloadTask: Task<Void, Never>?
    let model = ModelStore()
    let correctionModel = CorrectionModelStore()

    func open() -> Bool {
        guard confirmDiscard() else { return false }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { message = "Could not open this PDF. It may be locked or damaged."; return false }
        document = doc; pages = (0..<doc.pageCount).map { _ in DraftPage() }
        selectedPage = 0; selection = nil; draftSelection = nil; replacementUndo = nil; markerToInsert = nil; markerPageID = nil; projectURL = nil; showRemaining = false; dirty = true; message = "Ready: \(doc.pageCount) page(s)."
        return true
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Discard unsaved project changes?"; alert.informativeText = "Save the project to continue reviewing it later. Exporting a PDF does not save the project."
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func saveProject(asNew: Bool = false) {
        guard let document, let pdf = document.dataRepresentation() else { message = "Could not read the original PDF."; return }
        var destination = asNew ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Notes.pulp"
            guard panel.runModal() == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "pulp" { url.appendPathExtension("pulp") }
            destination = url
        }
        guard let destination else { return }
        let snapshot = ProjectFile(pdf: pdf, pages: pages.map { page in
            let status = ["Converting…", "Recognizing…", "Preparing model…", "Refining recognition…"].contains(page.status) ? "Not converted" : page.status
            return ProjectFile.Page(text: page.text, figures: page.figures, status: status)
        }, selectedPage: selectedPage)
        do {
            try snapshot.write(to: destination)
            projectURL = destination; dirty = false; message = "Project saved: \(destination.lastPathComponent)"
        } catch { showExportMessage(title: "Project was not saved", detail: error.localizedDescription); message = "Project save failed." }
    }

    func openProject() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try ProjectFile.read(from: url)
            let restored = try project.validatedDocument()
            document = restored
            pages = project.pages.map { saved in var page = DraftPage(); page.text = saved.text; page.figures = saved.figures; page.status = saved.status == "Not recognized" ? "Not converted" : saved.status; return page }
            selectedPage = project.selectedPage; selection = nil; draftSelection = nil; replacementUndo = nil
            markerToInsert = nil; markerPageID = nil; correctionProposal = nil; mathError = ""
            projectURL = url; showRemaining = true; dirty = false; message = "Project opened: \(url.lastPathComponent)"
        } catch { showExportMessage(title: "Project could not be opened", detail: error.localizedDescription); message = "Project open failed." }
    }

    func image(for index: Int) -> CGImage? {
        guard let page = document?.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2200 / max(bounds.width, bounds.height)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func recognize(_ index: Int) async {
        guard !processing, pages.indices.contains(index) else { return }
        if !pages[index].text.isEmpty {
            let alert = NSAlert(); alert.messageText = "Replace this page's draft?"
            alert.informativeText = "Recognition will replace the current text on this page. Other pages will keep their edits."
            alert.addButton(withTitle: "Replace Draft"); alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        idleUnloadTask?.cancel()
        processing = true; defer { processing = false; scheduleIdleUnload() }
        await recognizePreparedPage(index)
    }

    private func recognizePreparedPage(_ index: Int) async {
        let renderStart = ContinuousClock.now
        guard pages.indices.contains(index), let original = image(for: index), let image = RecognitionImage.downsample(original) else {
            message = "Could not prepare this page for recognition."
            if pages.indices.contains(index) { pages[index].status = message }
            return
        }
        let pageID = pages[index].id
        runningTimings[pageID] = PageTimings()
        runningTimings[pageID]?.pageRenderSeconds = PerformanceClock.seconds(since: renderStart)
        pages[index].status = "Preparing model…"
        let setupStart = ContinuousClock.now
        if !model.ready { await model.prepare() }
        runningTimings[pageID]?.ocrSetupSeconds = PerformanceClock.seconds(since: setupStart)
        guard let recognizer = model.recognizer else {
            pages[index].status = model.status
            pages[index].timings = runningTimings.removeValue(forKey: pageID) ?? PageTimings()
            return
        }
        await applyRecognition(index, image: image, recognizer: recognizer)
        if let current = pages.firstIndex(where: { $0.id == pageID }), let measured = runningTimings.removeValue(forKey: pageID) { pages[current].timings = measured }
    }

    func applyRecognition(_ index: Int, image: CGImage, recognizer: any PageRecognizing,
                          refine: (@MainActor (CGImage, DraftPage) async throws -> String)? = nil) async {
        guard pages.indices.contains(index) else { return }
        let pageID = pages[index].id; let revision = pages[index].revision
        pages[index].status = "Converting…"
        let recognitionStart = ContinuousClock.now
        do {
            let result = try await recognizer.recognize(image: image)
            guard let current = pages.firstIndex(where: { $0.id == pageID }) else { return }
            runningTimings[pageID]?.ocrRecognitionSeconds = PerformanceClock.seconds(since: recognitionStart)
            guard pages[current].revision == revision else { pages[current].status = "Draft changed while recognizing; your edits were kept."; return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pages[current].status = "No text recognized. You can type a draft or retry."; return }
            var refined: String?
            var refinementFailure: String?
            if let refine {
                pages[current].status = "Refining recognition…"
                message = "Refining page \(index + 1)…"
                var draft = pages[current]; draft.text = result
                do {
                    let suggestion = try await refine(image, draft)
                    guard !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CorrectionError.empty }
                    refined = suggestion
                }
                catch { refinementFailure = error.localizedDescription }
            }
            guard let latest = pages.firstIndex(where: { $0.id == pageID }) else { return }
            guard pages[latest].revision == revision else { pages[latest].status = "Draft changed while recognizing; your edits were kept."; return }
            if let refined {
                pages[latest].text = refined
                pages[latest].previousCorrection = (before: result, after: refined)
                pages[latest].status = "Refined draft ready. Compare it with the original page."
                message = "Page \(index + 1) is ready for review."
            } else {
                pages[latest].text = result
                pages[latest].previousCorrection = nil
                if let refinementFailure {
                    pages[latest].status = "Refinement failed; showing original recognition. Review this page."
                    message = "Page \(index + 1) refinement failed: \(refinementFailure)"
                } else {
                    pages[latest].status = RecognitionReview.hasRepeatedParagraphs(result)
                        ? "Possible repeated paragraphs. Check for missing or invented text."
                        : "Review the draft for errors."
                }
            }
            pages[latest].revision += 1
            dirty = true
        } catch {
            runningTimings[pageID]?.ocrRecognitionSeconds = PerformanceClock.seconds(since: recognitionStart)
            if let current = pages.firstIndex(where: { $0.id == pageID }) { pages[current].status = "Recognition failed: \(error.localizedDescription)" }
        }
    }

    private func refineRecognizedPage(image: CGImage, page: DraftPage) async throws -> String {
        let setupStart = ContinuousClock.now
        if !correctionModel.ready { await correctionModel.prepare() }
        runningTimings[page.id]?.correctionSetupSeconds = PerformanceClock.seconds(since: setupStart)
        guard correctionModel.ready else { throw CorrectionError.setup(correctionModel.status) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CorrectionError.failed }
        let correction = try await LocalCorrection.suggest(draft: page.text, image: png, directory: correctionModel.directory)
        let suggested = correction.text
        runningTimings[page.id]?.correctionModelLoadSeconds = correction.modelLoadSeconds
        runningTimings[page.id]?.correctionInferenceSeconds = correction.inferenceSeconds
        runningTimings[page.id]?.correctionTotalSeconds = correction.totalSeconds
        guard LocalCorrection.preservesFigures(page.figures, original: page.text, suggestion: suggested) else { throw CorrectionError.figureMarkers }
        var candidate = page; candidate.text = suggested
        let validationStart = ContinuousClock.now
        let (_, warnings) = try await PDFExporter().render(pages: [candidate])
        runningTimings[page.id]?.validationSeconds = PerformanceClock.seconds(since: validationStart)
        guard warnings.isEmpty, !RecognitionReview.hasRepeatedParagraphs(suggested), !RecognitionReview.hasUnsupportedCodeFence(suggested) else { throw CorrectionError.needsReview }
        return suggested
    }

    func compareEarlierDraft() {
        guard pages.indices.contains(selectedPage), let previous = pages[selectedPage].previousCorrection else { return }
        let page = pages[selectedPage]
        correctionProposal = CorrectionProposal(pageID: page.id, revision: page.revision, original: previous.before, proposed: page.text, hasRenderingIssues: false, isComparison: true)
    }

    func recognizeAll() async {
        guard !processing else { return }
        idleUnloadTask?.cancel()
        processing = true; batchCompleted = 0; batchIndex = 0; stopRequested = false; showRemaining = false
        for index in pages.indices {
            batchIndex = index
            // Preserve any existing edits and drafts; retry is an explicit page action.
            if pages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await recognizePreparedPage(index) }
            else { pages[index].status = "Existing draft kept. Review it for errors." }
            dirty = true
            batchCompleted = index + 1
            if stopRequested { break }
        }
        processing = false; batchIndex = nil
        scheduleIdleUnload()
        if stopRequested {
            stopRequested = false; showRemaining = true
            message = "Conversion stopped. Save the project or convert the remaining pages."
            saveProject()
        } else { showRemaining = true }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self else { return }
                if !self.processing && !self.model.busy { self.model.unload(); return }
            }
        }
    }

    func prepareModel() async {
        idleUnloadTask?.cancel()
        await model.prepare()
        scheduleIdleUnload()
    }

    var canEditSelectedPage: Bool {
        !processing || (batchIndex.map { selectedPage < $0 } ?? false)
    }

    func addSelection(replaceDraft: Bool = false) {
        guard canEditSelectedPage, pages.indices.contains(selectedPage), let rect = selection, let image = image(for: selectedPage) else { return }
        let page = pages[selectedPage]
        var replacement: Range<String.Index>?
        if replaceDraft {
            guard let selected = draftSelection, selected.length > 0, let range = Range(selected, in: page.text) else {
                message = "Select text in the draft, then select its region on the original page."; return
            }
            let fullText = page.text as NSString
            guard !page.figures.contains(where: {
                let markerRange = fullText.range(of: $0.marker)
                return markerRange.location != NSNotFound && NSIntersectionRange(selected, markerRange).length > 0
            }) else {
                message = "Select text without an existing figure marker."; return
            }
            replacement = range
        }
        let pixel = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height), width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixel.width >= 3, pixel.height >= 3, let crop = image.cropping(to: pixel) else { message = "Select a larger region."; return }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { message = "Could not create the crop."; return }
        let figure = Figure(id: UUID(), png: png); pages[selectedPage].figures.append(figure)
        if let replacement {
            let before = page.text
            let after = before.replacingCharacters(in: replacement, with: figure.marker)
            pages[selectedPage].text = after; pages[selectedPage].revision += 1
            replacementUndo = (page.id, before, after, figure.id)
            draftSelection = nil
            message = "Selected text replaced with the original crop."
        } else {
            markerPageID = page.id; markerToInsert = figure.marker
            message = "Figure added at the editing cursor. Move its marker to change its position."
        }
        selection = nil; dirty = true
    }

    func undoReplacement() {
        guard canEditSelectedPage, let undo = replacementUndo, pages.indices.contains(selectedPage), pages[selectedPage].id == undo.pageID,
              pages[selectedPage].text == undo.after else { return }
        pages[selectedPage].text = undo.before; pages[selectedPage].revision += 1
        pages[selectedPage].figures.removeAll { $0.id == undo.figureID }
        replacementUndo = nil; draftSelection = nil; dirty = true
        message = "Replacement undone."
    }

    func proposeCorrection() async {
        guard !processing, pages.indices.contains(selectedPage), let image = image(for: selectedPage) else { return }
        let index = selectedPage
        let page = pages[index]
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Recognize or write this page first."; return }
        guard page.text.count <= 12000 else { message = CorrectionError.tooLong.localizedDescription; return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { message = "Could not prepare the page image."; return }
        processing = true; defer { processing = false }
        let setupStart = ContinuousClock.now
        if !correctionModel.ready { await correctionModel.prepare() }
        let setupSeconds = PerformanceClock.seconds(since: setupStart)
        guard correctionModel.ready else { message = correctionModel.status; return }
        message = "Preparing a correction suggestion…"
        do {
            let correction = try await LocalCorrection.suggest(draft: page.text, image: png, directory: correctionModel.directory)
            let suggested = correction.text
            guard let current = pages.firstIndex(where: { $0.id == page.id }), pages[current].revision == page.revision else {
                message = "The draft changed during correction. Your edits were kept."; return
            }
            guard LocalCorrection.preservesFigures(page.figures, original: page.text, suggestion: suggested) else { throw CorrectionError.figureMarkers }
            var candidate = page; candidate.text = suggested
            let validationStart = ContinuousClock.now
            let (_, warnings) = try await PDFExporter().render(pages: [candidate])
            var timings = pages[current].timings
            timings.correctionSetupSeconds = setupSeconds
            timings.correctionModelLoadSeconds = correction.modelLoadSeconds
            timings.correctionInferenceSeconds = correction.inferenceSeconds
            timings.correctionTotalSeconds = correction.totalSeconds
            timings.validationSeconds = PerformanceClock.seconds(since: validationStart)
            pages[current].timings = timings
            correctionProposal = CorrectionProposal(pageID: page.id, revision: page.revision, original: page.text, proposed: suggested, hasRenderingIssues: !warnings.isEmpty || RecognitionReview.hasRepeatedParagraphs(suggested) || RecognitionReview.hasUnsupportedCodeFence(suggested))
            message = "Compare the suggestion with the original before using it."
        } catch { message = "Could not suggest a correction: \(error.localizedDescription)" }
    }

    func useCorrection(_ proposal: CorrectionProposal) {
        guard !proposal.hasRenderingIssues else {
            message = "The suggestion has rendering issues. The current draft was kept."; correctionProposal = nil; return
        }
        guard let index = pages.firstIndex(where: { $0.id == proposal.pageID }), pages[index].revision == proposal.revision else {
            message = "The draft changed. No suggestion was applied."; correctionProposal = nil; return
        }
        pages[index].previousCorrection = (before: pages[index].text, after: proposal.proposed)
        pages[index].text = proposal.proposed; pages[index].revision += 1
        pages[index].status = "Check the suggestion against the original."
        dirty = true; correctionProposal = nil
        message = "Suggestion applied. Review it before export."
    }

    func restoreBeforeCorrection() {
        guard pages.indices.contains(selectedPage), let previous = pages[selectedPage].previousCorrection else { return }
        if pages[selectedPage].text != previous.after {
            let alert = NSAlert(); alert.messageText = "Replace your later edits?"
            alert.informativeText = "Restoring the earlier draft replaces edits made after you applied the suggestion."
            alert.addButton(withTitle: "Restore Earlier Draft"); alert.addButton(withTitle: "Keep Current Draft")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pages[selectedPage].text = previous.before; pages[selectedPage].revision += 1
        pages[selectedPage].previousCorrection = nil
        pages[selectedPage].status = RecognitionReview.hasRepeatedParagraphs(previous.before)
            ? "Possible repeated paragraphs. Check for missing or invented text."
            : "Earlier draft restored. Review it for errors."
        dirty = true
        message = "Restored the draft from before the suggestion."
    }

    func export() async {
        guard !pages.isEmpty, !processing else { return }
        for (index, page) in pages.enumerated() {
            do { try DocumentHTML.validate(page) }
            catch {
                selectedPage = index; selection = nil
                let detail = "Page \(index + 1): \(error.localizedDescription)"
                message = "Export stopped: \(detail)"
                showExportMessage(title: "Check the draft before exporting", detail: detail + "\n\nYour edits are still here. Correct the draft and try again.")
                return
            }
        }
        processing = true; defer { processing = false }
        do {
            let (data, reviewPages) = try await PDFExporter().render(pages: pages)
            if !reviewPages.isEmpty {
                let list = reviewPages.map { String($0 + 1) }.joined(separator: ", ")
                let alert = NSAlert(); alert.messageText = "Some equations need review"
                alert.informativeText = "Check the original on page(s) \(list). Some recognized math may be incomplete or could not be displayed. The PDF will include review notices."
                alert.addButton(withTitle: "Keep Reviewing"); alert.addButton(withTitle: "Export With Notices")
                guard alert.runModal() == .alertSecondButtonReturn else { selectedPage = reviewPages[0]; return }
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Typeset Notes.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw ExportError.failed }
            message = "Exported and reopened: \(url.lastPathComponent)"
            showExportMessage(title: "PDF exported", detail: "Saved and reopened: \(url.path)")
        } catch {
            if let pageError = error as? PageExportError { selectedPage = pageError.index; selection = nil }
            message = "Export failed: \(error.localizedDescription)"
            showExportMessage(title: "PDF was not exported", detail: error.localizedDescription + "\n\nYour edits are still here.")
        }
    }

    private func showExportMessage(title: String, detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
