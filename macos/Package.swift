// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pulp",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Pulp", targets: ["Pulp"])],
    dependencies: [
        .package(url: "https://github.com/tansanrao/glm-ocr-swift.git", revision: "face7b96d5a1675af6594a532f86ca425f298777")
    ],
    targets: [
        .executableTarget(name: "Pulp", dependencies: [.product(name: "GlmOCRSwift", package: "glm-ocr-swift")], resources: [.copy("Resources")]),
        .testTarget(name: "PulpTests", dependencies: ["Pulp"])
    ]
)
