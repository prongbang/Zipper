// swift-tools-version:5.7
import PackageDescription
let package = Package(
    name: "Zipper",
    products: [
        .library(
            name: "Zipper",
            targets: ["Zipper"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Zipper",
            path: "Sources",
            publicHeadersPath: "."
        )
    ]
)