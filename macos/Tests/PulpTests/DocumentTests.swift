import XCTest
import PDFKit
@testable import Pulp

private struct FailedRecognizer: PageRecognizing {
    func recognize(image: CGImage) async throws -> String { throw CocoaError(.fileReadUnknown) }
}

private struct EmptyRecognizer: PageRecognizing {
    func recognize(image: CGImage) async throws -> String { " " }
}
private struct FixedRecognizer: PageRecognizing {
    func recognize(image: CGImage) async throws -> String { "Original OCR" }
}

final class DocumentTests: XCTestCase {
    func testProjectFileRoundTripAndInvalidFile() throws {
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let figure = Figure(id: UUID(), png: Data([1, 2, 3]))
        let page = ProjectFile.Page(text: "Corrected $x^2$ \(figure.marker)", figures: [figure], status: "Review the draft for errors.")
        let project = ProjectFile(pdf: try XCTUnwrap(pdf.dataRepresentation()), pages: [page], selectedPage: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pulp")
        defer { try? FileManager.default.removeItem(at: url) }
        try project.write(to: url)
        let restored = try ProjectFile.read(from: url)
        XCTAssertEqual(restored.pages[0].text, page.text)
        XCTAssertEqual(restored.pages[0].figures, [figure])
        XCTAssertEqual(restored.pages[0].status, page.status)
        XCTAssertEqual(try restored.validatedDocument().pageCount, 1)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try ProjectFile.read(from: url))
    }

    @MainActor
    func testReplaceSelectionWithCropAndUndo() throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); image.unlockFocus()
        let document = PDFDocument(); document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let workspace = Workspace(); workspace.document = document; workspace.pages = [DraftPage()]
        let original = "Before 😀 $x^2$ after"
        workspace.pages[0].text = original
        workspace.draftSelection = (original as NSString).range(of: "$x^2$")
        workspace.selection = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        workspace.addSelection(replaceDraft: true)
        let figure = try XCTUnwrap(workspace.pages[0].figures.first)
        XCTAssertEqual(workspace.pages[0].text, "Before 😀 \(figure.marker) after")
        XCTAssertNoThrow(try DocumentHTML.validate(workspace.pages[0]))
        workspace.undoReplacement()
        XCTAssertEqual(workspace.pages[0].text, original)
        XCTAssertTrue(workspace.pages[0].figures.isEmpty)
    }

    @MainActor
    func testBatchOnlyEnablesEditingOnProcessedPages() {
        let workspace = Workspace(); workspace.pages = [DraftPage(), DraftPage(), DraftPage()]
        workspace.processing = true; workspace.batchIndex = 1
        workspace.selectedPage = 0; XCTAssertTrue(workspace.canEditSelectedPage)
        workspace.selectedPage = 1; XCTAssertFalse(workspace.canEditSelectedPage)
        workspace.selectedPage = 2; XCTAssertFalse(workspace.canEditSelectedPage)
        workspace.processing = false; workspace.batchIndex = nil
        XCTAssertTrue(workspace.canEditSelectedPage)
    }

    @MainActor
    func testRecognitionDownsamplePreservesAspectRatioAndDoesNotUpscale() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2200, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let resized = try XCTUnwrap(RecognitionImage.downsample(image))
        XCTAssertEqual(resized.width, 1100)
        XCTAssertEqual(resized.height, 500)
        let unchanged = try XCTUnwrap(RecognitionImage.downsample(resized))
        XCTAssertEqual(unchanged.width, 1100)
        XCTAssertEqual(unchanged.height, 500)
        XCTAssertNil(RecognitionImage.downsample(image, maxDimension: 0))
    }

    func testMathDelimitersAndMarkers() throws {
        var page = DraftPage()
        page.text = "Prose $x^2$ and \\[\\frac{1}{2}\\]"
        XCTAssertNoThrow(try DocumentHTML.validate(page))
        XCTAssertFalse(DocumentHTML.repairMathDelimiters(page.text).needsReview)
        let repair = DocumentHTML.repairMathDelimiters("Incomplete $x^2\nNext line")
        XCTAssertTrue(repair.needsReview)
        XCTAssertEqual(repair.text, "Incomplete $x^2$\nNext line")
        XCTAssertEqual(DocumentHTML.repairMathDelimiters("Incomplete \\[x").text, "Incomplete \\[x\\]")
        XCTAssertTrue(DocumentHTML.repairMathDelimiters("Broken $\\frac{x$").needsReview)
        page.text = "Unknown [[figure:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE]]"
        XCTAssertThrowsError(try DocumentHTML.validate(page))
        let figure = Figure(id: UUID(), png: Data())
        page.figures = [figure]; page.text = figure.marker
        XCTAssertNoThrow(try DocumentHTML.validate(page))
    }

    func testTextIsEscaped() {
        XCTAssertEqual(DocumentHTML.escape("<img src=\"remote\"> &"), "&lt;img src=&quot;remote&quot;&gt; &amp;")
    }

    func testRepeatedLongParagraphsAreFlagged() {
        let paragraph = "The probability of the entire dataset is the product of the probabilities for each data point."
        XCTAssertTrue(RecognitionReview.hasRepeatedParagraphs([paragraph, paragraph, paragraph].joined(separator: "\n\n")))
        XCTAssertTrue(RecognitionReview.hasRepeatedParagraphs([paragraph, paragraph].joined(separator: "\n\n")))
        XCTAssertFalse(RecognitionReview.hasRepeatedParagraphs(paragraph))
        XCTAssertFalse(RecognitionReview.hasRepeatedParagraphs("yes\n\nyes\n\nyes"))
        XCTAssertTrue(RecognitionReview.hasUnsupportedCodeFence("```latex\nx^2\n```"))
        XCTAssertFalse(RecognitionReview.hasUnsupportedCodeFence("$x^2$"))
    }

    @MainActor
    func testCorrectionRequiresUnchangedDraftAndPreservesFigureMarkers() {
        let figure = Figure(id: UUID(), png: Data())
        let original = "Original " + figure.marker
        XCTAssertTrue(LocalCorrection.preservesFigures([figure], original: original, suggestion: "Edited " + figure.marker))
        XCTAssertFalse(LocalCorrection.preservesFigures([figure], original: original, suggestion: "Edited"))
        let workspace = Workspace()
        var page = DraftPage(); page.text = original; page.figures = [figure]
        workspace.pages = [page]
        let invalid = CorrectionProposal(pageID: page.id, revision: page.revision, original: original, proposed: "Broken", hasRenderingIssues: true)
        workspace.useCorrection(invalid)
        XCTAssertEqual(workspace.pages[0].text, original)
        let proposal = CorrectionProposal(pageID: page.id, revision: page.revision, original: original, proposed: "Edited " + figure.marker, hasRenderingIssues: false)
        workspace.pages[0].revision += 1
        workspace.useCorrection(proposal)
        XCTAssertEqual(workspace.pages[0].text, original)
        let updated = CorrectionProposal(pageID: page.id, revision: workspace.pages[0].revision, original: original, proposed: "Edited " + figure.marker, hasRenderingIssues: false)
        workspace.useCorrection(updated)
        XCTAssertEqual(workspace.pages[0].text, "Edited " + figure.marker)
        workspace.restoreBeforeCorrection()
        XCTAssertEqual(workspace.pages[0].text, original)
    }

    @MainActor
    func testExportFlagsAndPreservesInvalidEquations() async throws {
        _ = NSApplication.shared
        var missing = DraftPage(); missing.text = "Incomplete $x^2"
        var unsupported = DraftPage(); unsupported.text = "Unknown $\\notacommand{x}$"
        var valid = DraftPage(); valid.text = "Valid $x^2$"
        let (data, review) = try await PDFExporter().render(pages: [missing, unsupported, valid])
        XCTAssertEqual(review, [0, 1])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Check the equation") == true)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("notacommand") == true)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Check the equations") == true)
    }

    @MainActor
    func testFailedAndEmptyRecognitionPreserveDrafts() async throws {
        let workspace = Workspace()
        workspace.pages = [DraftPage(), DraftPage()]
        workspace.pages[0].text = "Corrected first page"
        workspace.pages[1].text = "Corrected second page"
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        await workspace.applyRecognition(0, image: image, recognizer: FailedRecognizer())
        XCTAssertTrue(workspace.pages[0].status.contains("Recognition failed"))
        XCTAssertEqual(workspace.pages.map(\.text), ["Corrected first page", "Corrected second page"])
        await workspace.applyRecognition(0, image: image, recognizer: EmptyRecognizer())
        XCTAssertTrue(workspace.pages[0].status.contains("No text recognized"))
        XCTAssertEqual(workspace.pages.map(\.text), ["Corrected first page", "Corrected second page"])
    }

    @MainActor
    func testRecognitionKeepsOriginalOutputWithoutCorrection() async throws {
        let workspace = Workspace(); workspace.pages = [DraftPage()]
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        await workspace.applyRecognition(0, image: image, recognizer: FixedRecognizer())
        XCTAssertEqual(workspace.pages[0].text, "Original OCR")
        XCTAssertNil(workspace.pages[0].previousCorrection)
        XCTAssertEqual(workspace.pages[0].status, "Review the draft for errors.")
    }

    @MainActor
    func testRecognitionRefinesAndFallsBackWithoutLosingEdits() async throws {
        let workspace = Workspace(); workspace.pages = [DraftPage()]
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        await workspace.applyRecognition(0, image: image, recognizer: FixedRecognizer()) { _, page in
            XCTAssertEqual(page.text, "Original OCR")
            return "Refined draft"
        }
        XCTAssertEqual(workspace.pages[0].text, "Refined draft")
        XCTAssertEqual(workspace.pages[0].previousCorrection?.before, "Original OCR")
        workspace.compareEarlierDraft()
        XCTAssertEqual(workspace.correctionProposal?.original, "Original OCR")
        XCTAssertTrue(workspace.correctionProposal?.isComparison == true)
        workspace.restoreBeforeCorrection()
        XCTAssertEqual(workspace.pages[0].text, "Original OCR")
        await workspace.applyRecognition(0, image: image, recognizer: FixedRecognizer()) { _, _ in throw CorrectionError.failed }
        XCTAssertEqual(workspace.pages[0].text, "Original OCR")
        XCTAssertTrue(workspace.pages[0].status.contains("Refinement failed"))
        await workspace.applyRecognition(0, image: image, recognizer: FixedRecognizer()) { _, _ in
            workspace.pages[0].text = "User edit"; workspace.pages[0].revision += 1
            return "Stale result"
        }
        XCTAssertEqual(workspace.pages[0].text, "User edit")
    }
}
