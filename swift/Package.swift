// swift-tools-version: 6.0

import PackageDescription

// swift-midi-file supports Apple platforms only: its compatibility table lists Linux as WIP,
// unlike swift-midi-core and swift-timecode underneath it. Gating the MIDI layer and everything
// above it off on Linux is what lets KSPKit -- the format core, M9-M11, and the bulk of the port
// -- build and test on the 1x runner. If upstream lands Linux support this conditional collapses.
#if os(Linux)
    let midiDependencies: [Package.Dependency] = []
    let midiProducts: [Product] = []
    let midiTargets: [Target] = []
#else
    let midiDependencies: [Package.Dependency] = [
        .package(url: "https://github.com/orchetect/swift-midi-file", from: "1.0.0"),
        // Runs on Linux too, but it is only ever needed by KSPSwiftCLI, which is gated off there
        // anyway -- declaring it here keeps the Linux job from fetching a package it cannot use.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ]
    let midiProducts: [Product] = [
        .executable(name: "ksp-swift-cli", targets: ["KSPSwiftCLI"])
    ]
    // KSPSwiftCLI, not ksp-swift-cli: a hyphen is legal in a product name but mangles a module name.
    let midiTargets: [Target] = [
        .target(
            name: "KSPMIDI",
            dependencies: [
                "KSPKit",
                .product(name: "SwiftMIDIFile", package: "swift-midi-file"),
            ]
        ),
        // The command bodies, as a library rather than as part of the executable below.
        //
        // SwiftPM forbids a non-test target from depending on an executable target, so anything
        // living in KSPSwiftCLI can only ever be reached by the CLI. M13's app needs the same
        // `convert` that `ksp-swift-cli convert` runs -- byte for byte, or the parity scripts stop
        // meaning anything -- so the runners sit here and both faces call them.
        .target(
            name: "KSPRun",
            dependencies: ["KSPMIDI"],
            // MCC's factory default, which `convert` overwrites when the user names no template.
            //
            // A SwiftPM resource must live under its own target's directory, and SwiftPM copies a
            // symlink *as a symlink* -- measured, with both `.copy` and `.process` -- which lands
            // a dangling link in the bundle. So the real bytes live here and
            // src/ksp_cli/templates/Default.KeyStepPro is the symlink instead: Python and
            // hatchling both follow one transparently, and the wheel carries the full 3.5 MB.
            // That keeps the repository at the two real copies it already had -- this one and the
            // untouchable sample in project_files/ -- rather than gaining a third.
            resources: [.copy("Resources/Default.KeyStepPro")]
        ),
        .executableTarget(
            name: "KSPSwiftCLI",
            dependencies: [
                "KSPRun",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "KSPMIDITests", dependencies: ["KSPMIDI"]),
        .testTarget(name: "KSPRunTests", dependencies: ["KSPRun"]),
        // Tests an executable target, which needs `@main` rather than a `main.swift`.
        .testTarget(name: "KSPSwiftCLITests", dependencies: ["KSPSwiftCLI"]),
    ]
#endif

let package = Package(
    name: "KeyStepProTool",
    // v14 because that is what the toolchain's Testing.framework is built for; anything lower
    // links with a version warning on every test build.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KSPKit", targets: ["KSPKit"])
    ] + midiProducts,
    dependencies: midiDependencies,
    targets: [
        .target(name: "KSPKit"),
        .testTarget(name: "KSPKitTests", dependencies: ["KSPKit"]),
    ] + midiTargets
)
