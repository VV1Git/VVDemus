// swift-tools-version:5.9

// Manifest for the vendored fork of Swifter. See README.md — this is NOT upstream's
// manifest. Upstream's also declares an `Example` executable and a `SwifterTests` test
// target whose source directories are not vendored, so only the library remains.

import PackageDescription

let package = Package(
    name: "Swifter",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Swifter", targets: ["Swifter"])
    ],
    targets: [
        .target(name: "Swifter")
    ]
)
