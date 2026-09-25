import AppKit
import KosmosCore
import KosmosRecovery
import KosmosSkyLight

/// The config file and what it resolves to on the connected displays (docs/config.md).
enum ConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/kosmos/kosmos.toml")
    }

    /// Kept without the files it includes, so it loads without them (docs/config.md).
    static var lastGood: URL { KosmosFiles.support.appending(path: "last-good.toml") }

    struct Loaded {
        var config: Config?
        var errors: [String] = []
        var warnings: [String] = []
        var source = "the config file"
    }

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

    /// Empty while NSScreen lists none, as it can in the middle of a display change.
    static func displays() -> [Display] {
        NSScreen.screens.map { screen in
            Display(id: screen.displayID, name: screen.localizedName, serial: DisplayIdentity.serial(of: screen.displayID),
                    isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0, frame: NSScreen.flipped(screen.frame),
                    area: NSScreen.flipped(screen.visibleFrame))
        }
    }

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

    /// `rect` flipped between AppKit's screen coordinates, whose origin is the primary
    /// display's bottom left, and Accessibility's, whose origin is its top left.
    static func flipped(_ rect: CGRect) -> CGRect {
        let height = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
