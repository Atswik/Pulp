import CoreImage
import CoreGraphics

@MainActor
enum RecognitionImage {
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func downsample(_ image: CGImage, maxDimension: Int = 1100) -> CGImage? {
        guard maxDimension > 0, image.width > 0, image.height > 0 else { return nil }
        let largest = max(image.width, image.height)
        guard largest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(largest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
