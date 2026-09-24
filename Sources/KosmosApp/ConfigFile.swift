import AppKit
import KosmosCore
import KosmosRecovery
import KosmosSkyLight

/// The config file at ~/.config/kosmos/kosmos.toml and what it resolves to on the connected
/// displays (DESIGN.md, section 5.8).
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/kosmos/kosmos.toml")
    }

    /// The last file that loaded without errors, used when the file is broken at launch.
    static var lastGood: URL { KosmosFiles.support.appending(path: "last-good.toml") }

    struct Loaded {
        /// Nil when there is nothing to apply.
        var config: Config?
        /// Problems that kept the config from loading.
        var errors: [String] = []
        /// Problems in a config that loaded anyway.
        var warnings: [String] = []
        /// Where `config` came from, for the log.
        var source = "the config file"
    }

    /// Reads and checks the config. At launch a broken file falls back to the last good one.
    static func load(atLaunch: Bool) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(config: nil, warnings: ["no config at \(url.path); using workspaces 1 to 9 and no bindings"],
                          source: "the defaults")
        }
        var loaded = Loaded()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let (config, diagnostics) = Config.load(text)
            loaded.errors = diagnostics.filter { $0.severity == .error }.map { "\(url.path):\($0)" }
            loaded.warnings = diagnostics.filter { $0.severity != .error }.map { "\(url.path):\($0)" }
            loaded.config = config
            if config != nil { try? text.write(to: lastGood, atomically: true, encoding: .utf8) }
        } catch {
            loaded.errors = ["cannot read \(url.path): \(error.localizedDescription)"]
        }
        if loaded.config == nil, atLaunch, let text = try? String(contentsOf: lastGood, encoding: .utf8),
           let config = Config.load(text).config {
            loaded.config = config
            loaded.source = "the last good config"
        }
        return loaded
    }

    /// The displays as the config's monitor matchers see them.
    static func displays() -> [Display] {
        NSScreen.screens.map { screen in
            Display(name: screen.localizedName, serial: DisplayIdentity.serial(of: screen.displayID),
                    isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0)
        }
    }

    static func gaps(_ config: Config, on display: Display) -> Gaps {
        let outer = config.outerGaps(on: display)
        return Gaps(inner: CGFloat(config.gaps.inner),
                    outer: Insets(top: CGFloat(outer.top), left: CGFloat(outer.left),
                                  bottom: CGFloat(outer.bottom), right: CGFloat(outer.right)))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
