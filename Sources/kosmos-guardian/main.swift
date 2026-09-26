// Restores concealed windows when Kosmos exits, however it exits, unless a Kosmos that
// starts right after it takes them over.
//
//   kosmos-guardian watch <pid>   Wait for Kosmos to exit and for a Kosmos to follow, then
//                                 run recovery. Prints "R" once the exit watch is armed;
//                                 Kosmos hides nothing before.
//   kosmos-guardian recover       Run recovery now, for use by hand, and print each
//                                 attempt's outcome.
import AppKit
import KosmosRecovery
import os

let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "guardian")
let arguments = Array(CommandLine.arguments.dropFirst())

// Bridged Space operations do nothing from a process that has not started AppKit
// (docs/overview.md).
NSApplication.shared.setActivationPolicy(.prohibited)

switch (arguments.first, arguments.dropFirst().first.flatMap(Int32.init)) {
case ("watch", let pid?): watch(pid)
case ("recover", nil): recover(printing: true, after: nil)
default:
    FileHandle.standardError.write(Data("usage: kosmos-guardian watch <pid> | recover\n".utf8))
    exit(2)
}

func watch(_ pid: Int32) -> Never {
    let queue = kqueue()
    var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                       fflags: NOTE_EXIT, data: 0, udata: nil)
    // Arming fails when Kosmos is already gone; recover at once.
    if kevent(queue, &event, 1, nil, 0, nil) == 0 {
        FileHandle.standardOutput.write(Data("R".utf8))
        var fired = kevent()
        while kevent(queue, nil, 0, &fired, 1, nil) < 0 && errno == EINTR {}
    }
    log.notice("Kosmos \(pid) exited")
    awaitSuccessor(of: pid)
    // Kosmos closed the pipe once it read "R", so a print would raise SIGPIPE.
    recover(printing: false, after: pid)
}

/// A Kosmos that names itself in the lock file within the grace takes the record over, so the
/// windows of hidden workspaces stay concealed. Any other holder of the lock, as a probe, takes
/// nothing over. The grace covers a crash restart and an install (docs/hiding.md).
func awaitSuccessor(of exited: Int32) {
    guard let record = RecordFile.peek(KosmosFiles.record), record.windowServer == ProcessIdentity.windowServer() else { return }
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if let kosmos = FileLock.successor(at: KosmosFiles.lock, excluding: exited) {
            log.notice("Kosmos \(kosmos.pid) took the record over; leaving it")
            exit(0)
        }
        usleep(50_000)
    }
    log.notice("no Kosmos took the record over within 5 s; recovering")
}

/// Retries for about 30 s, freeing the lock a starting Kosmos waits 3 s for (docs/overview.md).
func recover(printing: Bool, after exited: Int32?) -> Never {
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
        let outcome = attempt(after: exited)
        let line = outcome.map { String(describing: $0) } ?? "the lock is held by a process it does not name"
        log.notice("recovery: \(line, privacy: .public)")
        if printing { print(line) }
        if outcome?.isFinal == true { exit(0) }
        if ContinuousClock.now >= deadline { exit(1) }
        sleep(2)
    }
}

/// Nil while the lock is held by a process it does not name, as a probe or a Kosmos that has
/// not taken the record over yet.
func attempt(after exited: Int32?) -> Recovery.Outcome? {
    do {
        guard let lock = try FileLock(KosmosFiles.lock) else {
            guard let kosmos = FileLock.successor(at: KosmosFiles.lock, excluding: exited) else { return nil }
            log.notice("lock held by Kosmos \(kosmos.pid); leaving recovery to it")
            exit(0)
        }
        return try withExtendedLifetime(lock) { try Recovery.run(file: RecordFile(url: KosmosFiles.record)) }
    } catch {
        log.error("recovery failed: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}
