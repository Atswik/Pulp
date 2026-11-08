import AppKit
import Foundation

struct CorrectionRequest: Encodable {
    let modelDirectory: String
    let image: Data
    let draft: String
}
struct CorrectionResponse: Decodable {
    let proposal: String
    let modelLoadSeconds: Double
    let inferenceSeconds: Double
}

struct CorrectionResult: Sendable {
    let text: String
    let modelLoadSeconds: Double
    let inferenceSeconds: Double
    let totalSeconds: Double
}

struct CorrectionProposal: Identifiable {
    let id = UUID()
    let pageID: UUID
    let revision: Int
    let original: String
    let proposed: String
    let hasRenderingIssues: Bool
    var isComparison = false
}

enum CorrectionError: LocalizedError {
    case missingHelper, failed, empty, tooLong, figureMarkers, needsReview, setup(String)
    var errorDescription: String? {
        switch self {
        case .missingHelper: "The local correction helper is missing. Rebuild the app."
        case .failed: "The local correction model could not complete the request. Your draft is unchanged."
        case .empty: "The model returned no suggestion. Your draft is unchanged."
        case .tooLong: "This draft is too long for a safe correction attempt. Review it in smaller parts."
        case .figureMarkers: "The suggestion did not preserve the figure markers. Your draft is unchanged."
        case .needsReview: "The suggestion contains incomplete math, repeated text, or formatting the app cannot display."
        case .setup(let detail): detail
        }
    }
}

@MainActor
final class CorrectionModelStore: ObservableObject {
    @Published var busy = false
    @Published var ready = false
    @Published var progress = 0.0
    @Published var status = "Correction model not downloaded (about 3.1 GB)"
    private let cacheDirectory: URL?
    init(cacheDirectory: URL? = nil) { self.cacheDirectory = cacheDirectory }
    var directory: URL {
        cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulp/Models/Qwen3-VL-4B", isDirectory: true)
    }
    var hasDownloadedFiles: Bool { FileManager.default.fileExists(atPath: directory.path) }
    private let files: [(String, String)] = [
        ("added_tokens.json", "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        ("chat_template.jinja", "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4"),
        ("chat_template.json", "6f8a6a55027e3da5160105556cda5dd69f6423f1c32645f6730d32de7773d0c4"),
        ("config.json", "07406d087dfb8a8849427a4da81bc9edd1dd942e518493629b5a983169b47820"),
        ("generation_config.json", "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44"),
        ("merges.txt", "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        ("model.safetensors", "90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca"),
        ("model.safetensors.index.json", "58a7841d7bff2548dd91577d216274a83cf1b500bc6a534b809d6c1b1707cf2b"),
        ("preprocessor_config.json", "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5"),
        ("special_tokens_map.json", "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        ("tokenizer.json", "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        ("tokenizer_config.json", "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5"),
        ("video_preprocessor_config.json", "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1"),
        ("vocab.json", "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
    ]
    func prepare() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b/"
            for (index, entry) in files.enumerated() {
                let (name, expected) = entry
                let destination = directory.appendingPathComponent(name)
                status = "Checking correction model: \(name)"
                if FileManager.default.fileExists(atPath: destination.path), try await ModelStore.hash(destination) == expected {
                    progress = Double(index + 1) / Double(files.count); continue
                }
                status = "Downloading correction model: \(name)"
                let delegate = DownloadProgress { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.progress = (Double(index) + fraction) / Double(self?.files.count ?? 1) }
                }
                let (temporary, response) = try await URLSession.shared.download(from: URL(string: base + name)!, delegate: delegate)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ModelError.download(name) }
                guard try await ModelStore.hash(temporary) == expected else { throw ModelError.checksum(name) }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                progress = Double(index + 1) / Double(files.count)
            }
            ready = true; status = "Correction model ready"
        } catch { ready = false; status = "Correction setup failed: \(error.localizedDescription)" }
    }
    func remove() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            ready = false; progress = 0; status = "Correction model removed"
        } catch { status = "Could not remove correction model: \(error.localizedDescription)" }
    }
}

enum LocalCorrection {
    static func suggest(draft: String, image: Data, directory: URL) async throws -> CorrectionResult {
        guard draft.count <= 12000 else { throw CorrectionError.tooLong }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CorrectionHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw CorrectionError.missingHelper }
        let input = try JSONEncoder().encode(CorrectionRequest(modelDirectory: directory.path, image: image, draft: draft))
        return try await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            let process = Process(); process.executableURL = helper
            let stdin = Pipe(); let stdout = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let response = try? JSONDecoder().decode(CorrectionResponse.self, from: output) else { throw CorrectionError.failed }
            let suggestion = response.proposal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suggestion.isEmpty else { throw CorrectionError.empty }
            return CorrectionResult(text: suggestion, modelLoadSeconds: response.modelLoadSeconds,
                                    inferenceSeconds: response.inferenceSeconds, totalSeconds: PerformanceClock.seconds(since: start))
        }.value
    }
    static func preservesFigures(_ figures: [Figure], original: String, suggestion: String) -> Bool {
        figures.allSatisfy { figure in
            original.components(separatedBy: figure.marker).count == suggestion.components(separatedBy: figure.marker).count
        }
    }
}
