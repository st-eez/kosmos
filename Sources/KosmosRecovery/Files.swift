import Foundation

public enum KosmosFiles {
    public static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Kosmos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }()

    /// Held by the running Kosmos, and by whoever runs recovery.
    public static var lock: URL { support.appending(path: "kosmos.lock") }
    public static var record: URL { support.appending(path: "recovery.record") }
    public static var layout: URL { support.appending(path: "layout.json") }
}

/// Released when the descriptor closes, so also when the process dies.
public final class FileLock {
    private let fd: Int32

    /// Nil when another process holds the lock.
    public init?(_ url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A failed init of a class still runs deinit, which closes fd.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
    }

    deinit { close(fd) }

    /// Writes `holder` into the file. A Kosmos names itself once it takes the recovery record
    /// over, and a guardian leaves the record only to a live Kosmos named there (docs/hiding.md).
    public func name(_ holder: ProcessIdentity) {
        let text = Array("\(holder.pid) \(holder.start)\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, text, text.count, 0)
    }

    /// The process last named in the lock file at `url`, which may have exited since.
    public static func holder(_ url: URL) -> ProcessIdentity? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = Int32(fields[0]), let start = UInt64(fields[1]) else { return nil }
        return ProcessIdentity(pid: pid, start: start)
    }
}
