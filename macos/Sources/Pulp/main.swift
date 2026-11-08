import Foundation
import AppKit
import GlmOCRSwift
import PDFKit

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--benchmark" {
    let model = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let penalty = Float(ProcessInfo.processInfo.environment["NOTES_BENCHMARK_REPETITION_PENALTY"] ?? "1.1") ?? 1.1
    let prompt = ProcessInfo.processInfo.environment["NOTES_BENCHMARK_PROMPT"] ?? "Text Recognition:"
    let config = GlmOCRConfig(recognizerModelID: model, layoutModelID: model, enableLayout: false, recognitionOptions: .init(maxTokens: 1200, temperature: 0, topP: 1, topK: 1, repetitionPenalty: penalty), prompts: .init(noLayoutPrompt: prompt))
    let start = Date()
    let pipeline = try await GlmOCRPipeline(config: config)
    let result = try await pipeline.parse(.imageData(data), options: .init())
    print(result.markdown)
    FileHandle.standardError.write(Data("Elapsed: \(Date().timeIntervalSince(start)) seconds\n".utf8))
} else if CommandLine.arguments.count == 3 && ["--profile-document", "--profile-document-drafts"].contains(CommandLine.arguments[1]) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    guard let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])), !document.isLocked, document.pageCount > 0 else { throw CocoaError(.fileReadUnknown) }
    let workspace = Workspace(); workspace.document = document
    workspace.pages = (0..<document.pageCount).map { _ in DraftPage() }
    let start = ContinuousClock.now
    await workspace.recognizeAll()
    struct ProfilePage: Encodable { let page: Int; let status: String; let timings: PageTimings; let text: String? }
    struct Profile: Encodable { let totalSeconds: Double; let pages: [ProfilePage] }
    let includeDrafts = CommandLine.arguments[1] == "--profile-document-drafts"
    let result = Profile(totalSeconds: PerformanceClock.seconds(since: start), pages: workspace.pages.enumerated().map { ProfilePage(page: $0.offset + 1, status: $0.element.status, timings: $0.element.timings, text: includeDrafts ? $0.element.text : nil) })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(result))
} else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--rasterize-recognition" {
    guard let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])),
          let index = Int(CommandLine.arguments[3]), index >= 0, index < document.pageCount else { throw CocoaError(.fileReadUnknown) }
    let workspace = Workspace(); workspace.document = document
    guard let source = workspace.image(for: index), let resized = RecognitionImage.downsample(source),
          let png = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
} else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--rasterize" {
    let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard let index = Int(CommandLine.arguments[3]), let page = document?.page(at: index) else { throw CocoaError(.fileReadUnknown) }
    let bounds = page.bounds(for: .mediaBox); let scale = 2200 / max(bounds.width, bounds.height)
    let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--correction-setup-check" {
    let store = CorrectionModelStore(cacheDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
    await store.prepare()
    print(store.status)
    if !store.ready { exit(1) }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--setup-check" {
    let store = ModelStore(cacheDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
    await store.prepare()
    print(store.status)
    if !store.ready { exit(1) }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--remove-check" {
    let store = ModelStore(cacheDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
    store.remove()
    print(store.status)
    if store.status != "Model removed" { exit(1) }
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--validate-draft" {
    await MainActor.run { _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory) }
    let text = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    var draft = DraftPage(); draft.text = text
    let (_, warnings) = try await PDFExporter().render(pages: [draft])
    print(warnings.isEmpty ? "valid" : "review")
} else if CommandLine.arguments.count == 3 && ["--export-check", "--export-long-check"].contains(CommandLine.arguments[1]) {
    await MainActor.run {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }
    let figure = try await MainActor.run { () -> Figure in
        let image = NSImage(size: NSSize(width: 240, height: 100))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 100).fill()
        NSColor.black.setStroke(); let path = NSBezierPath(rect: NSRect(x: 25, y: 25, width: 190, height: 50)); path.lineWidth = 3; path.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return Figure(id: UUID(), png: png)
    }
    var first = DraftPage(); first.text = "Fixture heading\nSelectable corrected prose.\nInline $x^2$ and display: \\[\\frac{1}{1+x}\\]\n" + figure.marker; first.figures = [figure]
    if CommandLine.arguments[1] == "--export-long-check" {
        first.text = (1...100).map { "Line \($0): selectable text in reading order." }.joined(separator: "\n") + "\n" + figure.marker
    }
    var second = DraftPage(); second.text = "Second page follows in order."
    let exporter = PDFExporter()
    try await exporter.export(pages: [first, second], to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("Export created")
} else {
    PulpApp.main()
}
