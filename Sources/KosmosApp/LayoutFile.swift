import Foundation
import KosmosCore
import KosmosRecovery
import os

private let layoutLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "layout")

/// The saved layout, beside the recovery record (docs/tree.md). Each write replaces the file
/// whole by a rename, so a crash leaves the last one.
enum LayoutFile {
    static let version = 1

    /// WindowServer numbers the windows, so under another one the ids name other windows.
    private struct Contents: Codable {
        var version: Int
        var windowServer: ProcessIdentity
        var layout: SavedLayout
    }

    /// Writes stay in order, off the main thread.
    private static let writes = DispatchQueue(label: "kosmos.layout", qos: .utility)
    /// The layout the file holds, touched only on `writes`, so a failed write is tried again.
    nonisolated(unsafe) private static var written: SavedLayout?

    /// Nil for a file of another version or WindowServer.
    static func load(under windowServer: ProcessIdentity) -> SavedLayout? {
        guard let data = try? Data(contentsOf: KosmosFiles.layout) else { return nil }
        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            layoutLog.error("\(KosmosFiles.layout.path, privacy: .public) not read: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard contents.version == version, contents.windowServer == windowServer else {
            let why = contents.version == version ? "from another WindowServer" : "of version \(contents.version)"
            layoutLog.notice("saved layout left out: \(why, privacy: .public)")
            return nil
        }
        return contents.layout
    }

    /// Skips a layout the file holds already. `wait`: returns once the file holds `layout`, as
    /// at quit.
    static func write(_ layout: SavedLayout, under windowServer: ProcessIdentity, wait: Bool = false) {
        let work: @Sendable () -> Void = {
            guard layout != written else { return }
            do {
                let contents = Contents(version: version, windowServer: windowServer, layout: layout)
                try JSONEncoder().encode(contents).write(to: KosmosFiles.layout, options: .atomic)
                written = layout
            } catch {
                layoutLog.error("\(KosmosFiles.layout.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        if wait { writes.sync(execute: work) } else { writes.async(execute: work) }
    }
}
