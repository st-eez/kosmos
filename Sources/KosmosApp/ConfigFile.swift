import AppKit
import KosmosCore

/// The config file at ~/.config/kosmos/kosmos.toml and what it resolves to on the connected
/// displays (DESIGN.md, section 5.8).
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/kosmos/kosmos.toml")
    }

    /// The config, or nil with the problems to show. A missing file is not an error: Kosmos
    /// runs with nine workspaces and no bindings.
    static func load() -> (config: Config?, problems: [String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, ["no config at \(url.path); using workspaces 1 to 9 and no bindings"])
        }
        let (config, diagnostics) = Config.load(text)
        return (config, diagnostics.map { "\(url.path):\($0)" })
    }

    /// The displays as the config's monitor matchers see them. Serial numbers come with
    /// several monitors.
    static func displays() -> [Display] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Display(name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    static func gaps(_ config: Config, on display: Display) -> Gaps {
        let outer = config.outerGaps(on: display)
        return Gaps(inner: CGFloat(config.gaps.inner),
                    outer: Insets(top: CGFloat(outer.top), left: CGFloat(outer.left),
                                  bottom: CGFloat(outer.bottom), right: CGFloat(outer.right)))
    }
}
