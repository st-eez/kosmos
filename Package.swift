// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kosmos",
    platforms: [.macOS("27.0")],
    targets: [
        // Private SkyLight declarations, and the holding Space and focus operations. The
        // framework ships with macOS.
        .target(
            name: "CSkyLight",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
                .linkedFramework("Carbon"),
            ]
        ),
        // The model: trees, layout and commands. No AppKit and no Accessibility.
        .target(name: "KosmosCore"),
        // The socket protocol, server and client. No AppKit, so the CLI stays fast to launch.
        .target(name: "KosmosIPC"),
        // Swift wrappers for SkyLight queries and events.
        .target(name: "KosmosSkyLight", dependencies: ["CSkyLight"]),
        // The recovery record and procedure, shared by the app and the guardian.
        .target(name: "KosmosRecovery", dependencies: ["CSkyLight", "KosmosSkyLight"]),
        .executableTarget(name: "KosmosApp", dependencies: ["CSkyLight", "KosmosCore", "KosmosIPC", "KosmosRecovery", "KosmosSkyLight"]),
        .executableTarget(name: "kosmos", dependencies: ["KosmosIPC"]),
        .executableTarget(name: "kosmos-guardian", dependencies: ["KosmosRecovery"]),
        // Measurements of private behaviour that the design depends on (DESIGN.md, section 6).
        .executableTarget(name: "kosmos-probe", dependencies: ["CSkyLight", "KosmosRecovery", "KosmosSkyLight"]),
        .testTarget(name: "KosmosCoreTests", dependencies: ["KosmosCore"]),
        .testTarget(name: "KosmosIPCTests", dependencies: ["KosmosIPC"]),
        .testTarget(name: "KosmosRecoveryTests", dependencies: ["KosmosRecovery"]),
    ]
)
