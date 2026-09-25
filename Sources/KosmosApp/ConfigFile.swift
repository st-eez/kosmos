import AppKit
import KosmosCore
import KosmosRecovery
import KosmosSkyLight

/// The config file at ~/.config/kosmos/kosmos.toml and what it resolves to on the connected
/// displays (docs/config.md).
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/kosmos/kosmos.toml")
    }

    /// The last file that loaded without errors, used when the file is broken at launch. The
    /// files it includes are not kept, so it loads without them.
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

    /// Reads and checks the config and the files it includes. At launch a broken config falls
    /// back to the last good file.
    static func load(atLaunch: Bool) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Loaded(config: nil, warnings: ["no config at \(url.path); using workspaces 1 to 9 and no bindings"],
                          source: "the defaults")
        }
        var loaded = Loaded()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let directory = url.deletingLastPathComponent()
            let (config, diagnostics) = Config.load(text) { try? String(contentsOf: directory.appending(path: $0), encoding: .utf8) }
            func located(_ diagnostic: Diagnostic) -> String {
                "\(diagnostic.file.map { directory.appending(path: $0).path } ?? url.path):\(diagnostic)"
            }
            loaded.errors = diagnostics.filter { $0.severity == .error }.map(located)
            loaded.warnings = diagnostics.filter { $0.severity != .error }.map(located)
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

    /// The connected displays, as the config's monitor matchers and the session see them.
    /// Empty while NSScreen lists none, as it can in the middle of a change.
    static func displays() -> [Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        // AppKit's origin is the primary display's bottom left; Accessibility's is its top left.
        func flipped(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { screen in
            Display(id: screen.displayID, name: screen.localizedName, serial: DisplayIdentity.serial(of: screen.displayID),
                    isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0, frame: flipped(screen.frame),
                    area: flipped(screen.visibleFrame))
        }
    }

    /// Each display by SketchyBar's number for it (BarSnapshot.displayNumber).
    static func barDisplays(_ displays: [Display]) -> [DisplayID: BarSnapshot.Display] {
        let active = DisplayIdentity.active().count, managed = DisplayIdentity.managed()
        return Dictionary(uniqueKeysWithValues: displays.map { display in
            let number = BarSnapshot.displayNumber(uuid: DisplayIdentity.uuid(of: display.id), active: active, managed: managed)
            return (display.id, BarSnapshot.Display(id: number, name: display.name))
        })
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
