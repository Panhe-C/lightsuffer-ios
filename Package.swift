// swift-tools-version: 5.9
//
// light suffer胶片 — iOS app
// Pure-Swift port of the spektrafilm physical film-simulation engine.
//
// The `FilmPhysics` target is deliberately free of any Apple-only framework
// so that the numerical core can be built and tested on Linux (the CI box)
// as well as on macOS / iOS.
//
// The `FilmPhysicsMetal` target is the GPU port of the same pipeline: every
// file of it is wrapped in `#if canImport(Metal)`, so the target compiles to
// nothing on Linux (the CPU reference is built and tested there) and the
// Metal Shading Language source is compiled at runtime.

import PackageDescription

let package = Package(
    name: "lightsuffer-ios",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FilmPhysics", targets: ["FilmPhysics"]),
        .library(name: "FilmPhysicsMetal", targets: ["FilmPhysicsMetal"]),
        .library(name: "LightSufferPreview", targets: ["LightSufferPreview"]),
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
        .target(
            name: "FilmPhysicsMetal",
            dependencies: ["FilmPhysics"],
            resources: [
                // The Metal Shading Language source is copied as a resource
                // and compiled at runtime (`makeLibrary(source:options:)`);
                // SwiftPM does not compile the `.metal` files.
                .copy("Shaders"),
            ]
        ),
        .target(
            name: "LightSufferPreview",
            dependencies: ["FilmPhysics"]
        ),
        .testTarget(
            name: "FilmPhysicsTests",
            dependencies: ["FilmPhysics"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "FilmPhysicsMetalTests",
            dependencies: ["FilmPhysicsMetal", "FilmPhysics"]
        ),
        .testTarget(
            name: "LightSufferPreviewTests",
            dependencies: ["LightSufferPreview", "FilmPhysics"]
        ),
    ]
)
