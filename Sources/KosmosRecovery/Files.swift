import Foundation

/// Kosmos's private directory, created with mode 0700, and the files the app and the
/// guardian share.
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

/// An exclusive lock on a file, held until the descriptor closes or the process dies.
public final class FileLock {
    private let fd: Int32

    /// Nil when another process holds the lock.
    public init?(_ url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
    }

    deinit { close(fd) }
}
