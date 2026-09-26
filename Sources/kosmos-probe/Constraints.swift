// What WindowServer's size constraints tell Kosmos of a window's minimum, and what reading
// them costs (docs/geometry.md).
//
//   kosmos-probe constraints        Two windows of the probe's, one with a minimum frame size
//                                   and one with a minimum content size set through AppKit,
//                                   as the row iterator and the package read their
//                                   constraints; the constraints of every other app's window
//                                   at level 0, read and never touched; and what reading the
//                                   minimums adds to the inventory's row read of 2 windows
//                                   and of every window.
import AppKit
import CKosmos
import KosmosSkyLight

private struct Constraints {
    var minimum = CGSize.zero, maximum = CGSize.zero, current = CGSize.zero
}

/// Each window's constraints as the row iterator reads them.
private func iteratorConstraints(_ ids: [UInt32]) -> [UInt32: Constraints] {
    guard let query = SLSWindowQueryWindows(SkyLight.connection, ids as CFArray, Int32(ids.count)) else { return [:] }
    defer { query.release() }
    guard let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) else { return [:] }
    defer { iterator.release() }
    let it = iterator.takeUnretainedValue()
    var read: [UInt32: Constraints] = [:]
    while SLSWindowIteratorAdvance(it) {
        var c = Constraints()
        _ = SLSWindowIteratorGetConstraints(it, &c.minimum, &c.maximum, &c.current)
        read[SLSWindowIteratorGetWindowID(it)] = c
    }
    return read
}

private func packageConstraints(_ id: UInt32) -> (Constraints, CGError) {
    var c = Constraints()
    let error = SLSPackagesGetWindowConstraints(SkyLight.connection, id, &c.minimum, &c.maximum, &c.current)
    return (c, error)
}

private func describe(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

private func describe(_ c: Constraints) -> String {
    "minimum \(describe(c.minimum)), maximum \(describe(c.maximum)), current \(describe(c.current))"
}

@MainActor func constraints() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let area = builtInScreen().visibleFrame
    func window(_ title: String, at x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: area.minX + x, y: area.minY + 16, width: 520, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }
    let framed = window("kosmos-probe minimum frame 480x300", at: 16)
    framed.minSize = NSSize(width: 480, height: 300)
    let content = window("kosmos-probe minimum content 400x250", at: 560)
    content.contentMinSize = NSSize(width: 400, height: 250)
    for window in [framed, content] { window.orderFrontRegardless() }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    let own = [UInt32(framed.windowNumber), UInt32(content.windowNumber)]
    let read = iteratorConstraints(own)
    for (label, window) in [("minimum frame", framed), ("minimum content", content)] {
        let id = UInt32(window.windowNumber)
        let (package, error) = packageConstraints(id)
        print("""
            \(label) \(id): AppKit minSize \(describe(window.minSize)), frame \(describe(window.frame.size)); \
            iterator \(read[id].map(describe) ?? "no row"); package \(describe(package)), error \(error.rawValue)
            """)
    }

    // Every other app's window at level 0 with no parent, as the inventory's candidates.
    let rows = SkyLight.rows(SkyLight.allWindowIDs()).filter { $0.level == 0 && $0.parent == 0 && $0.pid != getpid() }
    let others = iteratorConstraints(rows.map(\.id))
    var fallbacks = 0
    for row in rows.sorted(by: { $0.pid == $1.pid ? $0.id < $1.id : $0.pid < $1.pid }) {
        let name = NSRunningApplication(processIdentifier: row.pid)?.localizedName ?? "pid \(row.pid)"
        let iterator = others[row.id] ?? Constraints()
        let empty = iterator.minimum == .zero && iterator.maximum == .zero
        if empty { fallbacks += 1 }
        let package = packageConstraints(row.id).0
        print("""
            \(name) \(row.id) \(row.orderedIn ? "in" : "out"), frame \(describe(row.frame.size)): \
            iterator \(describe(iterator))\(empty ? ", package \(describe(package))" : "")
            """)
    }
    print("\(rows.count) windows, \(fallbacks) read from the package")

    // What the minimums add to the inventory's reads, the two reads alternating.
    func time(_ ids: [UInt32], rounds: Int) -> (plain: Double, minimums: Double) {
        var plain: [Double] = [], withMinimums: [Double] = []
        for _ in 0..<rounds {
            var start = ContinuousClock.now
            _ = SkyLight.rows(ids, cornerRadii: true)
            plain.append(elapsed(start))
            start = .now
            _ = SkyLight.rows(ids, cornerRadii: true, minimums: true)
            withMinimums.append(elapsed(start))
        }
        return (percentile(plain, 0.5), percentile(withMinimums, 0.5))
    }
    let two = time(own, rounds: 5000)
    print(String(format: "rows of 2 windows with radii: %.4f ms median, with the minimums too %.4f ms", two.plain, two.minimums))
    let all = SkyLight.allWindowIDs()
    let every = time(all, rounds: 500)
    print(String(format: "rows of all %d windows with radii: %.4f ms median, with the minimums too %.4f ms",
                 all.count, every.plain, every.minimums))
    var package: [Double] = []
    for _ in 0..<5000 {
        let start = ContinuousClock.now
        _ = packageConstraints(own[0])
        package.append(elapsed(start))
    }
    print(String(format: "a package read of 1 window: %.4f ms median", percentile(package, 0.5)))
    for window in [framed, content] { window.orderOut(nil) }
}
