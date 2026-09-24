import Foundation

/// Holds an exclusive lock on a file for the life of the process, so a second Kosmos exits
/// instead of managing the same windows. The kernel releases the lock when the process dies,
/// including after a crash.
struct InstanceLock {
    private let fd: Int32

    init(directory: URL) throws {
        let path = directory.appending(path: "kosmos.lock").path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.open(path, errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LockError.held(path)
        }
    }

    enum LockError: LocalizedError {
        case open(String, Int32)
        case held(String)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code): "Cannot open \(path): \(String(cString: strerror(code)))"
            case .held(let path): "Another Kosmos is running (\(path) is locked)"
            }
        }
    }
}
