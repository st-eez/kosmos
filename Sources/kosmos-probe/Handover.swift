// A holding Space across the process that made it (docs/hiding.md).
//
//   kosmos-probe handover   Whether a holding Space outlives the process that created it,
//                           keeps hiding what it holds, and takes a window another process
//                           adds, as a Kosmos that takes over the record needs. A child makes
//                           the Space and conceals one window in it, then exits, and in a
//                           second round kills itself; the probe then adds a second window,
//                           removes both and destroys the Space. Both windows are invisible,
//                           off every display, in apps that can never be front, so it runs
//                           beside a live session.
import AppKit
import CKosmos
import KosmosSkyLight

@MainActor func handover() {
    _ = NSApplication.shared   // bridged operations need an AppKit client
    var results: [String] = []
    for killed in [false, true] {
        let (first, concealed) = spawnPanel("hidden-window")
        let (second, added) = spawnPanel("hidden-window")
        defer {
            first.terminate()
            second.terminate()
        }
        let creator = Child(["handover-creator", String(concealed)] + (killed ? ["kill"] : []))
        guard let space = UInt64(creator.line()), space != 0 else {
            print("the child created no holding Space")
            continue
        }
        creator.process.waitUntilExit()
        let ending = killed ? "killed by SIGKILL" : "exited with status \(creator.process.terminationStatus)"
        print("round \(killed ? 2 : 1): child \(creator.pid) made Space \(space), concealed \(concealed) in it, and \(ending)")
        var ids = [concealed, added]
        defer {
            kosmos_remove_windows(space, &ids, 2)
            kosmos_space_destroy(space)
        }

        func state(_ step: String) -> (listed: Bool, hides: Bool) {
            _ = kosmos_barrier(space)
            let members = SkyLight.windows(in: space)
            var transform = CGAffineTransform.identity, alpha: Float = -1
            let read = kosmos_space_read(space, &transform, &alpha)
            let hides = read && transform.tx == 100_000 && transform.ty == 100_000 && alpha == 0
            let rows = Dictionary(SkyLight.rows([concealed, added]).map { ($0.id, $0.orderedIn) }) { first, _ in first }
            print("  \(step): members \(members.map { "\($0.sorted())" } ?? "nil (gone or unread)"), "
                  + (read ? "transform \(transform.tx), \(transform.ty), alpha \(alpha)" : "transform and alpha unread")
                  + ", \(concealed) ordered in \(rows[concealed].map { "\($0)" } ?? "no row"), ordinary Spaces "
                  + "\(SkyLight.spaces(of: concealed) ?? [])")
            return (members != nil, hides)
        }
        let atEnd = state("the child gone")
        Thread.sleep(forTimeInterval: 1)
        let later = state("1 s later")
        kosmos_add_windows(space, [added], 1, false)
        _ = state("\(added) added by this process")
        let took = inSpace(added, space)
        let kept = inSpace(concealed, space)
        kosmos_remove_windows(space, &ids, 2)
        _ = state("both removed by this process")
        let removed = !inSpace(concealed, space) && !inSpace(added, space)
        kosmos_space_destroy(space)
        _ = kosmos_barrier(space)
        var destroyed = false
        for _ in 0..<10 where !destroyed {
            destroyed = SkyLight.windows(in: space) == nil
            if !destroyed { Thread.sleep(forTimeInterval: 0.1) }
        }
        results.append("""
            child \(killed ? "killed" : "exited"): Space listed \(atEnd.listed && later.listed), still hiding \
            \(atEnd.hides && later.hides), \(concealed) still in it \(kept), add from another process landed \(took), \
            removals landed \(removed), destroyed \(destroyed)
            """)
    }
    results.forEach { print($0) }
}

/// Makes a holding Space as Kosmos does, conceals `window` in it, prints the Space's id and
/// ends, with `kill` by SIGKILL, as a crash would.
@MainActor func handoverCreator(_ window: UInt32, kill killed: Bool) -> Never {
    _ = NSApplication.shared
    let space = kosmos_holding_create()
    guard space != 0 else {
        print(0)
        exit(1)
    }
    kosmos_add_windows(space, [window], 1, false)
    _ = kosmos_barrier(space)
    print(space)
    if killed { kill(getpid(), SIGKILL) }
    exit(0)
}
