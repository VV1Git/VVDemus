// swift-tools-version:5.9

// Manifest for the vendored fork of Swifter. See README.md — this is NOT upstream's
// manifest. Upstream's also declares an `Example` executable and a `SwifterTests` test
// target whose source directories are not vendored, so only the library remains.

import PackageDescription

let package = Package(
    name: "Swifter",
    // macOS is here so the Mac app can embed the same server the phone runs — both peers
    // serve the same routes and the same WebUI. A floor, not a target: the apps themselves
    // deploy far later than this, and the library is POSIX sockets and Foundation.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Swifter", targets: ["Swifter"])
    ],
    targets: [
        .target(name: "Swifter")
    ]
)
