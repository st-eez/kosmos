// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kosmos",
    platforms: [.macOS("27.0")],
    targets: [
        // Private SkyLight and CoreDisplay declarations, and the holding Space and focus
        // operations. Both frameworks ship with macOS.
        .target(
            name: "CKosmos",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreDisplay"),
            ]
        ),
        // The model: trees, layout and commands. No AppKit and no Accessibility.
        .target(name: "KosmosCore"),
        // The socket protocol, server and client. No Foundation or AppKit, so the CLI stays
        // fast to launch.
        .target(name: "KosmosIPC"),
        // Swift wrappers for SkyLight queries and events.
        .target(name: "KosmosSkyLight", dependencies: ["CKosmos"]),
        // The recovery record and procedure, shared by the app and the guardian.
        .target(name: "KosmosRecovery", dependencies: ["CKosmos", "KosmosSkyLight"]),
        .executableTarget(name: "KosmosApp", dependencies: ["CKosmos", "KosmosCore", "KosmosIPC", "KosmosRecovery", "KosmosSkyLight"]),
        // Swift Build links Foundation into every executable. Dropping unused libraries keeps it
        // out of the CLI, where loading it would add about 1.8 ms to each launch.
        .executableTarget(
            name: "kosmos",
            dependencies: ["KosmosIPC"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip_dylibs"])]
        ),
        .executableTarget(name: "kosmos-guardian", dependencies: ["KosmosRecovery"]),
        // Measurements of private behaviour that the design depends on
        // (docs/overview.md, section 6).
        .executableTarget(name: "kosmos-probe", dependencies: ["CKosmos", "KosmosCore", "KosmosIPC", "KosmosRecovery", "KosmosSkyLight"]),
        .testTarget(name: "KosmosCoreTests", dependencies: ["KosmosCore"]),
        .testTarget(name: "KosmosIPCTests", dependencies: ["KosmosIPC"]),
        .testTarget(name: "KosmosRecoveryTests", dependencies: ["KosmosRecovery"]),
        .testTarget(name: "KosmosSkyLightTests", dependencies: ["KosmosSkyLight"]),
    ]
)
