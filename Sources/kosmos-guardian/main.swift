// Restores concealed windows when Kosmos exits, however it exits.
//
//   kosmos-guardian watch <pid>   Wait for Kosmos to exit, then run recovery. Prints "R"
//                                 once the exit watch is armed; Kosmos hides nothing before.
//   kosmos-guardian recover       Run recovery now, for use by hand.
import AppKit
import KosmosRecovery
import os

let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "guardian")
let arguments = Array(CommandLine.arguments.dropFirst())

// The bridged Space operations are refused for a process that is not an AppKit client.
// Prohibited keeps the guardian out of the Dock and Command-Tab.
NSApplication.shared.setActivationPolicy(.prohibited)

switch (arguments.first, arguments.dropFirst().first.flatMap(Int32.init)) {
case ("watch", let pid?): watch(pid)
case ("recover", nil): recover()
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
    recover()
}

func recover() -> Never {
    do {
        // A new Kosmos that already holds the lock runs recovery itself at startup.
        guard let lock = try FileLock(KosmosFiles.lock) else {
            log.notice("lock held by a running Kosmos; leaving recovery to it")
            exit(0)
        }
        let outcome = Recovery.run(file: try RecordFile(url: KosmosFiles.record))
        log.notice("recovery: \(String(describing: outcome), privacy: .public)")
        print(outcome)
        withExtendedLifetime(lock) {}
        if case .incomplete = outcome { exit(1) }
        exit(0)
    } catch {
        log.error("recovery failed: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}
