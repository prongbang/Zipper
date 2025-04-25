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
        // .binaryTarget(
        //     name: "Zipper",
        //     url: "https://github.com/prongbang/cocoapods-to-xcframework/releases/download/1.2.0/Zipper.xcframework.zip",
        //     checksum: "ea364256a0298732a11489262684a9eeba6abaa54242addbe4eb0a6af79c3883"
        // )
    ]
)