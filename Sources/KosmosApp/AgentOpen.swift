import AppKit

/// The app `kosmos open` opens, named as `open` takes it, whose new windows Kosmos sends to the
/// agent workspace (docs/ipc.md).
enum AgentOpen {
    /// For `-a <name or path>`, `-b <bundle id>`, or a file or URL; nil when no app is found.
    static func bundleID(_ arguments: [String]) -> String? {
        switch (arguments.first, arguments.count) {
        // The app's own bundle id, in its own case, as the inventory compares it exactly.
        case ("-b", 2): NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments[1]).flatMap { Bundle(url: $0)?.bundleIdentifier }
        case ("-a", 2): app(named: arguments[1])
        case (let target?, 1): opener(of: target)
        default: nil
        }
    }

    /// A path, a running app's name, or an app in the folders `open -a` searches first.
    private static func app(named name: String) -> String? {
        if name.contains("/") { return Bundle(url: URL(fileURLWithPath: name))?.bundleIdentifier }
        let name = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            return Bundle(url: url)?.bundleIdentifier
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        return folders.lazy.compactMap { Bundle(path: "\($0)/\(name).app")?.bundleIdentifier }.first
    }

    private static func opener(of target: String) -> String? {
        let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: target)
        return url.flatMap(NSWorkspace.shared.urlForApplication(toOpen:)).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
