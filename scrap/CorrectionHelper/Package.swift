// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CorrectionHelper",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "CorrectionHelper", targets: ["CorrectionHelper"])],
    dependencies: [.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.30.6")],
    targets: [.executableTarget(name: "CorrectionHelper", dependencies: [.product(name: "MLXVLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm")])]
)
