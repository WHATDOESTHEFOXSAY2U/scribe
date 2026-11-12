// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3")
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
