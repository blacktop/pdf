// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "pdf",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "pdf", targets: ["pdf"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.2")
    ],
    targets: [
        .executableTarget(
            name: "pdf",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            linkerSettings: [
                .linkedFramework("PDFKit")
            ]
        ),
        .testTarget(
            name: "pdfTests",
            dependencies: ["pdf"]
        )
    ]
)
