import AppKit
import UniformTypeIdentifiers

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

    /// A path, a running app's name, or an app LaunchServices knows by that name, in a folder
    /// of its own too, as Adobe Acrobat in /Applications/Adobe Acrobat DC.
    private static func app(named name: String) -> String? {
        if name.contains("/") { return Bundle(url: URL(fileURLWithPath: name))?.bundleIdentifier }
        let name = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            return Bundle(url: url)?.bundleIdentifier
        }
        // Deprecated with no replacement that takes a name, and it still answered on macOS 27
        // (2026-10-07); the protocol keeps its warning out.
        return (NSWorkspace.shared as AppPaths).fullPath(forApplication: name).flatMap { Bundle(path: $0)?.bundleIdentifier }
    }

    /// A file's opener by the type its name gives, as reading the file asks TCC in a folder
    /// such as ~/Downloads, which held the main thread 5.3 s (2026-10-08). A file's own Open
    /// With choice goes unseen. The CLI ends a folder's path with a slash.
    private static func opener(of target: String) -> String? {
        let workspace = NSWorkspace.shared
        if target.contains("://") {
            return URL(string: target).flatMap(workspace.urlForApplication(toOpen:)).flatMap { Bundle(url: $0)?.bundleIdentifier }
        }
        let url = URL(fileURLWithPath: target)
        if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
        let types = [UTType(filenameExtension: url.pathExtension), url.hasDirectoryPath ? .folder : .data]
        return types.lazy.compactMap { $0.flatMap(workspace.urlForApplication(toOpen:)) }.first.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

private protocol AppPaths {
    func fullPath(forApplication: String) -> String?
}

extension NSWorkspace: AppPaths {}
