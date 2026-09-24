// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kosmos",
    platforms: [.macOS("27.0")],
    targets: [
        // Declarations for private SkyLight calls. The framework ships with macOS.
        .target(
            name: "CSkyLight",
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        ),
        // The model: trees, layout and commands. No AppKit and no Accessibility.
        .target(name: "KosmosCore"),
        // The socket protocol, server and client. No AppKit, so the CLI stays fast to launch.
        .target(name: "KosmosIPC"),
        .executableTarget(name: "KosmosApp", dependencies: ["CSkyLight", "KosmosCore", "KosmosIPC"]),
        .executableTarget(name: "kosmos", dependencies: ["KosmosIPC"]),
        .executableTarget(name: "kosmos-guardian", dependencies: ["CSkyLight"]),
        .testTarget(name: "KosmosCoreTests", dependencies: ["KosmosCore"]),
        .testTarget(name: "KosmosIPCTests", dependencies: ["KosmosIPC"]),
    ]
)
