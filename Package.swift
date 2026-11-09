// swift-tools-version: 5.9
//
// light suffer胶片 — iOS app
// Pure-Swift port of the spektrafilm physical film-simulation engine.
//
// The `FilmPhysics` target is deliberately free of any Apple-only framework
// so that the numerical core can be built and tested on Linux (the CI box)
// as well as on macOS / iOS.

import PackageDescription

let package = Package(
    name: "lightsuffer-ios",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FilmPhysics", targets: ["FilmPhysics"]),
    ],
    targets: [
        .target(
            name: "FilmPhysics",
            resources: [
                .copy("Resources/profiles"),
                .copy("Resources/spectral"),
                .copy("Resources/filters"),
                .copy("Resources/CHANGELOG.txt"),
            ]
        ),
        .testTarget(
            name: "FilmPhysicsTests",
            dependencies: ["FilmPhysics"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
