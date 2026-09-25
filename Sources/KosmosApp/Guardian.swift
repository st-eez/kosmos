import Foundation
import os

private let guardianLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "guardian")

/// Keeps kosmos-guardian running. It sits in its own process group, so a signal to Kosmos's
/// group or the end of its launchd job leaves it alive to restore windows. Kosmos may hide
/// windows only while `isReady` (docs/overview.md, section 4.1).
@MainActor
final class Guardian {
    private(set) var isReady = false
    /// Called when the guardian keeps dying and Kosmos stops trying: nothing may stay
    /// concealed without it.
    var onUnavailable: (@MainActor () -> Void)?
    private var exitSource: DispatchSourceProcess?
    private var recentExits: [ContinuousClock.Instant] = []

    private var helper: URL {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/kosmos-guardian")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // A development build runs from .build, next to the helper.
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "kosmos-guardian")
    }

    func start() { spawn() }

    private func spawn() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            guardianLog.error("pipe failed: \(errno)")
            return failed()
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO)

        let path = helper.path
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("watch"), strdup(String(getpid())), nil]
        defer { argv.forEach { free($0) } }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, path, &actions, &attributes, argv, environ)
        let pid = spawned
        close(fds[1])
        guard result == 0 else {
            close(fds[0])
            guardianLog.error("cannot start \(path, privacy: .public): \(result)")
            return failed()
        }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.exited(pid) } }
        source.resume()
        exitSource = source

        let readFD = fds[0]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var poller = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            var byte: UInt8 = 0
            let ready = poll(&poller, 1, 5000) == 1 && read(readFD, &byte, 1) == 1 && byte == UInt8(ascii: "R")
            close(readFD)
            onMain {
                guard let self, self.exitSource === source else { return }
                self.isReady = ready
                if ready { guardianLog.info("guardian \(pid) ready") } else { guardianLog.error("guardian \(pid) not ready") }
            }
        }
    }

    /// Respawns at once, unless the helper keeps dying.
    private func exited(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        exitSource?.cancel()
        exitSource = nil
        guardianLog.error("guardian \(pid) exited with status \(status)")
        failed()
    }

    /// A guardian that could not start or has exited: try again, unless it keeps failing,
    /// in which case every concealed window is restored.
    private func failed() {
        isReady = false
        let now = ContinuousClock.now
        recentExits = recentExits.filter { now - $0 < .seconds(10) } + [now]
        guard recentExits.count <= 3 else {
            guardianLog.fault("guardian exited 4 times in 10 s; hiding stays off")
            onUnavailable?()
            return
        }
        // Once a second, so a spawn that fails at once cannot spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.spawn() }
        }
    }
}
