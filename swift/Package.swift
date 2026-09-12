// swift-tools-version: 6.0

import PackageDescription

// swift-midi-file is Apple-only, so the MIDI layer and everything above it is gated off on
// Linux to keep KSPKit building there.
#if os(Linux)
    let midiDependencies: [Package.Dependency] = []
    let midiProducts: [Product] = []
    let midiTargets: [Target] = []
#else
    let midiDependencies: [Package.Dependency] = [
        .package(url: "https://github.com/orchetect/swift-midi-file", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ]
    let midiProducts: [Product] = [
        .executable(name: "kspplus", targets: ["KSPSwiftCLI"]),
        // SwiftPM builds the binary; scripts/bundle_app.sh wraps it in the .app.
        .executable(name: "ksp-app", targets: ["KSPApp"]),
        .library(name: "KSPRun", targets: ["KSPRun"]),
    ]
    // The target is KSPSwiftCLI and the product kspplus: a product name is the binary's filename.
    let midiTargets: [Target] = [
        .target(
            name: "KSPMIDI",
            dependencies: [
                "KSPKit",
                .product(name: "SwiftMIDIFile", package: "swift-midi-file"),
            ]
        ),
        // Its own target because CoreMIDI is Apple-only and KSPKit builds on the Linux runner.
        .target(name: "KSPDevice", dependencies: ["KSPKit"]),
        // SwiftPM forbids a non-test target from depending on an executable target, so the
        // command bodies live here and both faces call them.
        .target(
            name: "KSPRun",
            dependencies: ["KSPMIDI", "KSPDevice"],
            // SwiftPM copies a symlink *as a symlink*, landing a dangling link in the bundle,
            // so the real bytes live here and every other copy links to this one.
            resources: [.copy("Resources/Default.KeyStepPro")]
        ),
        .executableTarget(
            name: "KSPSwiftCLI",
            dependencies: [
                "KSPRun",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "KSPApp", dependencies: ["KSPRun"]),
        .testTarget(name: "KSPMIDITests", dependencies: ["KSPMIDI", "KSPTestSupport"]),
        .testTarget(name: "KSPDeviceTests", dependencies: ["KSPDevice", "KSPTape"]),
        .testTarget(name: "KSPRunTests", dependencies: ["KSPRun", "KSPTape", "KSPTestSupport"]),
        // Tests an executable target, which needs `@main` rather than a `main.swift`.
        .testTarget(name: "KSPSwiftCLITests", dependencies: ["KSPSwiftCLI", "KSPTestSupport"]),
        .testTarget(name: "KSPAppTests", dependencies: ["KSPApp", "KSPMIDI", "KSPTestSupport"]),
    ]
#endif

let package = Package(
    name: "KeyStepProTool",
    // v14 is what the toolchain's Testing.framework is built for; lower warns on every build.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KSPKit", targets: ["KSPKit"])
    ] + midiProducts,
    dependencies: midiDependencies,
    targets: [
        .target(name: "KSPKit"),
        // SwiftPM cannot share a source file between two test targets, but it can give them
        // all a target to depend on. Outside KSPKit, or the app would ship a fake device.
        .target(name: "KSPTape", dependencies: ["KSPKit"]),
        .target(name: "KSPTestSupport", dependencies: ["KSPKit"]),
        .testTarget(name: "KSPKitTests", dependencies: ["KSPKit", "KSPTape", "KSPTestSupport"]),
    ] + midiTargets
)
