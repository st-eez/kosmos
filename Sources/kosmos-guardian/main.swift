// Restores concealed windows when Kosmos exits, however it exits.
//
//   kosmos-guardian watch <pid>   Wait for Kosmos to exit, then run recovery. Prints "R"
//                                 once the exit watch is armed; Kosmos hides nothing before.
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
case ("recover", nil): recover(printing: true)
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
    // Kosmos closed the pipe once it read "R", so a print would raise SIGPIPE.
    recover(printing: false)
}

/// Runs recovery until it is final, every 2 s for about 30 s: without launch at login, no
/// other recovery comes until Kosmos is started again.
func recover(printing: Bool) -> Never {
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
        let outcome = attempt()
        log.notice("recovery: \(String(describing: outcome), privacy: .public)")
        if printing { print(outcome) }
        if outcome.isFinal || ContinuousClock.now >= deadline { exit(outcome.isFinal ? 0 : 1) }
        sleep(2)
    }
}

/// One recovery, under the lock. The lock is released between attempts, since a starting
/// Kosmos waits only 3 s for it; one that took it runs recovery itself.
func attempt() -> Recovery.Outcome {
    do {
        guard let lock = try FileLock(KosmosFiles.lock) else {
            log.notice("lock held by a running Kosmos; leaving recovery to it")
            exit(0)
        }
        return try withExtendedLifetime(lock) { try Recovery.run(file: RecordFile(url: KosmosFiles.record)) }
    } catch {
        log.error("recovery failed: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}
