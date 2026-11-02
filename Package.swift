// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nisla",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Nisla", targets: ["Nisla"])],
    targets: [
        .executableTarget(
            name: "Nisla",
            path: "Sources/Nisla",
            exclude: ["Resources"]
        )
    ]
)
