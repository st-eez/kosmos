import Foundation
import KosmosCore
import KosmosRecovery
import os

private let layoutLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "layout")

/// The saved layout, beside the recovery record (docs/tree.md). Each write replaces the file
/// whole by a rename, so a crash leaves the last one.
enum LayoutFile {
    static var url: URL { KosmosFiles.support.appending(path: "layout.json") }

    /// Writes stay in order, off the main thread.
    private static let writes = DispatchQueue(label: "kosmos.layout", qos: .utility)
    /// The layout the file holds, touched only on `writes`, so a failed write is tried again.
    nonisolated(unsafe) private static var written: SavedLayout?

    /// The WindowServer running now, which numbers the windows.
    static func windowServer() -> SavedLayout.Process? {
        ProcessIdentity.windowServer().map { SavedLayout.Process(pid: $0.pid, start: $0.start) }
    }

    static func load() -> SavedLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SavedLayout.self, from: data)
        } catch {
            layoutLog.error("\(url.path, privacy: .public) not read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Skips a layout the file holds already. `wait`: returns once the file holds `layout`, as
    /// at quit.
    static func write(_ layout: SavedLayout, wait: Bool = false) {
        let work: @Sendable () -> Void = {
            guard layout != written else { return }
            do {
                try JSONEncoder().encode(layout).write(to: url, options: .atomic)
                written = layout
            } catch {
                layoutLog.error("\(url.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        if wait { writes.sync(execute: work) } else { writes.async(execute: work) }
    }
}
