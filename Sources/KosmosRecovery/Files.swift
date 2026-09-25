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
}
