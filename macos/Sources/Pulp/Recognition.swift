import AppKit
import CryptoKit
import Foundation
import GlmOCRSwift
import MLX

protocol PageRecognizing: Sendable {
    func recognize(image: CGImage) async throws -> String
}

enum RecognitionReview {
    static func hasUnsupportedCodeFence(_ text: String) -> Bool {
        text.contains("```") || text.contains("~~~")
    }
    // This catches long, exactly repeated paragraphs; it does not prove the rest is correct.
    static func hasRepeatedParagraphs(_ text: String) -> Bool {
        var counts: [String: Int] = [:]
        for paragraph in text.components(separatedBy: "\n\n") {
            let normalized = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard normalized.count >= 60 else { continue }
            counts[normalized, default: 0] += 1
            if counts[normalized, default: 0] >= 2 { return true }
        }
        return false
    }
}

actor GLMRecognizer: PageRecognizing {
    private let pipeline: GlmOCRPipeline

    init(modelDirectory: URL) async throws {
        // The package validates a layout path even when layout is disabled.
        // Point it at the same existing model directory; it is never loaded as a detector.
        let path = modelDirectory.path
        let config = GlmOCRConfig(
            recognizerModelID: path, layoutModelID: path, enableLayout: false,
            recognitionOptions: .init(maxTokens: 1200, temperature: 0, topP: 1, topK: 1),
            prompts: .init(noLayoutPrompt: "Text Recognition:")
        )
        pipeline = try await GlmOCRPipeline(config: config)
    }

    func recognize(image: CGImage) async throws -> String {
        let result = try await pipeline.parse(.image(image), options: .init())
        return result.markdown
    }
}

final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var progress = 0.0
    @Published var status = "Model not downloaded (about 2.2 GB)"
    @Published var busy = false
    @Published var ready = false
    private(set) var recognizer: GLMRecognizer?
    private let cacheDirectory: URL?

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
        if hasDownloadedFiles { status = "Model on disk; loads when needed" }
    }

    private let files: [(String, String)] = [
        ("chat_template.jinja", "062e7ee4cc8defa88a5938b5d456dc60366ffd80647f918946ee747bf09ddc7c"),
        ("config.json", "7bf6a133be2edf17779af72f5fb7e9252199ef58fe6b29c26bf249c071087354"),
        ("generation_config.json", "4e2a3412f65b2a21d315d928986c55723d3e60dfb92c3982a5b9fd56835b0aa5"),
        ("model.safetensors", "3e93839427cf081600cd96651ba4d9edf6d6120f042555eb9fcfa36153905f74"),
        ("model.safetensors.index.json", "b25dcc93cd6c638d344ee12f9a0da2352c7fe6673debc5c324d248637480549b"),
        ("preprocessor_config.json", "02cc50c36240882ae35e8cd4077a25a379664108185d728d261cb785aefeccff"),
        ("processor_config.json", "19dafea5bd6415c50e2da43a31583dab39f9496673260ad33d9fa6c638a1d077"),
        ("tokenizer.json", "aa0fd058c73a5718bb191f6672dc16d122ee0147b20c123d1726514298f9968a"),
        ("tokenizer_config.json", "7a76fcb27abbc2cb0249d81884fef972b2c27194e3e13db54baae50f58f141fb")
    ]
    private var directory: URL {
        cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulp/Models/GLM-OCR", isDirectory: true)
    }

    var hasDownloadedFiles: Bool {
        let url = ProcessInfo.processInfo.environment["NOTES_MODEL_DIR"].map { URL(fileURLWithPath: $0) } ?? directory
        return files.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0.0).path) }
    }

    func unload() {
        guard !busy, recognizer != nil else { return }
        recognizer = nil; ready = false; progress = 0
        Memory.clearCache()
        status = "Model on disk; loads when needed"
    }

    func prepare() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let override = ProcessInfo.processInfo.environment["NOTES_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
            let modelURL = override ?? directory
            if override == nil {
                try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
                let base = "https://huggingface.co/mlx-community/GLM-OCR-bf16/resolve/24f15402e83baa0a80eeeaecf5480e172abc6f2e/"
                for (index, entry) in files.enumerated() {
                    let (name, expected) = entry
                    let destination = modelURL.appendingPathComponent(name)
                    status = "Checking \(name)"
                    if FileManager.default.fileExists(atPath: destination.path), try await Self.hash(destination) == expected {
                        progress = Double(index + 1) / Double(files.count); continue
                    }
                    status = "Downloading \(name)"
                    let delegate = DownloadProgress { [weak self] fraction in
                        Task { @MainActor [weak self] in self?.progress = (Double(index) + fraction) / Double(self?.files.count ?? 1) }
                    }
                    let (temporary, response) = try await URLSession.shared.download(from: URL(string: base + name)!, delegate: delegate)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ModelError.download(name) }
                    guard try await Self.hash(temporary) == expected else { throw ModelError.checksum(name) }
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    progress = Double(index + 1) / Double(files.count)
                }
            }
            status = "Loading model"
            recognizer = try await GLMRecognizer(modelDirectory: modelURL)
            ready = true; progress = 1; status = "Model ready"
        } catch {
            ready = false; status = "Model setup failed: \(error.localizedDescription)"
        }
    }

    func remove() {
        guard !busy else { return }
        recognizer = nil; ready = false; progress = 0
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            status = "Model removed"
        } catch { status = "Could not remove model: \(error.localizedDescription)" }
    }

    nonisolated static func hash(_ url: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

enum ModelError: LocalizedError {
    case download(String), checksum(String)
    var errorDescription: String? {
        switch self {
        case .download(let name): "Could not download \(name)."
        case .checksum(let name): "The downloaded \(name) did not pass verification."
        }
    }
}
