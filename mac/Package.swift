// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlinkMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BlinkMac", targets: ["BlinkMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "BlinkMac",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/BlinkMac"
        )
    ],
    swiftLanguageModes: [.v5]
)
