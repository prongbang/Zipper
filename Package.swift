// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "Zipper",
    platforms: [
        .iOS(.v11)
    ],
    products: [
        .library(
            name: "Zipper",
            targets: ["Zipper"]
        )
    ],
    targets: [
        .target(
            name: "Zipper",
            path: "Zipper"
        )
    ]
)
