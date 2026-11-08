import Foundation

struct PageTimings: Codable {
    var pageRenderSeconds: Double?
    var ocrSetupSeconds: Double?
    var ocrRecognitionSeconds: Double?
    var correctionSetupSeconds: Double?
    var correctionModelLoadSeconds: Double?
    var correctionInferenceSeconds: Double?
    var correctionTotalSeconds: Double?
    var validationSeconds: Double?
    var previewSeconds: Double?
}

enum PerformanceClock {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
