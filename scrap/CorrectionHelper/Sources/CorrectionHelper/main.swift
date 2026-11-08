import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM
import MLX

// Experimental benchmark setting. The application does not pass this option.
if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--cache-limit-mb=") }),
   let megabytes = Int(argument.dropFirst("--cache-limit-mb=".count)), megabytes >= 0,
   megabytes <= Int.max / 1_000_000 {
    Memory.cacheLimit = megabytes * 1_000_000
}

struct Request: Decodable {
    let modelDirectory: String
    let image: Data
    let draft: String
}
struct Response: Encodable {
    let proposal: String?
    let modelLoadSeconds: Double
    let inferenceSeconds: Double
    let error: String?
    var mlxActiveBytes: Int? = nil
    var mlxCacheBytes: Int? = nil
    var mlxPeakActiveBytes: Int? = nil
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}

func respond(to request: Request, model: ModelContainer, loadSeconds: Double) async throws -> Response {
    // A fresh session is essential: no page or KV-cache history may leak into the next page.
    let session = ChatSession(model, generateParameters: .init(maxTokens: 1600, temperature: 0), processing: .init(resize: nil))
    let prompt = """
    Transcribe the handwritten notes from the image. The OCR draft below may repeat text, omit text, or contain incorrect equations. Correct it using only the image. Do not add text or equations unsupported by the image. Preserve meaning, symbols, and any figure markers in the draft. Format equations in LaTeX. Return only the corrected transcript.

    OCR draft:
    \(request.draft)
    """
    let start = ContinuousClock.now
    let proposal: String
    if CommandLine.arguments.contains("--text-only") {
        let textPrompt = """
        Conservatively repair obvious formatting errors in this OCR draft. You cannot see the source. Preserve all wording, symbols, equations, and uncertain content; do not guess missing text or rewrite. Only fix unambiguous LaTeX syntax and formatting. Return only the draft, without code fences.

        OCR draft:
        \(request.draft)
        """
        proposal = try await session.respond(to: textPrompt)
    } else {
        guard let image = CIImage(data: request.image) else { throw CocoaError(.fileReadCorruptFile) }
        proposal = try await session.respond(to: prompt, image: .ciImage(image))
    }
    let memory = Memory.snapshot()
    return Response(proposal: proposal, modelLoadSeconds: loadSeconds, inferenceSeconds: seconds(since: start), error: nil,
                    mlxActiveBytes: memory.activeMemory, mlxCacheBytes: memory.cacheMemory, mlxPeakActiveBytes: memory.peakMemory)
}

func emit(_ response: Response, newline: Bool) throws {
    let data = try JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    if newline { FileHandle.standardOutput.write(Data([10])) }
}

if CommandLine.arguments.contains("--persistent") {
    var loaded: ModelContainer?
    var loadedDirectory: String?
    while let line = readLine() {
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            guard loadedDirectory == nil || loadedDirectory == request.modelDirectory else { throw CocoaError(.fileReadUnknown) }
            var loadSeconds = 0.0
            if loaded == nil {
                let start = ContinuousClock.now
                loaded = try await VLMModelFactory.shared.loadContainer(configuration: .init(directory: URL(fileURLWithPath: request.modelDirectory)))
                loadedDirectory = request.modelDirectory
                loadSeconds = seconds(since: start)
            }
            guard let model = loaded else { throw CocoaError(.fileReadUnknown) }
            try emit(try await respond(to: request, model: model, loadSeconds: loadSeconds), newline: true)
        } catch {
            try? emit(Response(proposal: nil, modelLoadSeconds: 0, inferenceSeconds: 0, error: "The local correction request failed."), newline: true)
        }
    }
} else {
    do {
        let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let start = ContinuousClock.now
        let model = try await VLMModelFactory.shared.loadContainer(configuration: .init(directory: URL(fileURLWithPath: request.modelDirectory)))
        try emit(try await respond(to: request, model: model, loadSeconds: seconds(since: start)), newline: false)
    } catch {
        FileHandle.standardError.write(Data("Correction failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
