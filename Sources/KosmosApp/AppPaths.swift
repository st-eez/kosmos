import Foundation

enum AppPaths {
    /// Kosmos's private directory, created with mode 0700. The socket and the instance lock
    /// live here.
    static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Kosmos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }()
}
