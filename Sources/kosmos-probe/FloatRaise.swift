// Whether a background app's window can be ordered above the front app's windows without
// keying it or activating its app, as a floating window over a tile needs
// (docs/focus-follows-mouse.md).
//
// AXRaise is AppKit's makeKeyAndOrderFront:, which in an app that is not active orders the
// window front conditionally. WindowServer's _compareTimesAndApps refuses that while the window
// it last recorded as front belongs to the front process, and _safeTestAndOrder then orders the
// window just below that one. With no recorded window it allows the order. SLSSetFrontWindow
// sets the record, and its handler checks no rights (SkyLight on macOS 27, 26A428).
//
//   kosmos-probe float-raise [trials]
//                                   Two child apps that are never front, B (accessory) and C
//                                   (prohibited), open one small window each at the bottom
//                                   left of the built-in display, C's overlapping B's. W is
//                                   the front app's frontmost window at the normal level, read
//                                   and named, never changed. Each trial has the children send
//                                   their windows to the back of the normal level, sets the
//                                   record to W, as a click on W leaves it, and then:
//                                     control    AXRaise B1
//                                     clear      record cleared, then AXRaise B1
//                                     own        record set to B1, then AXRaise B1
//                                     still      record cleared, no AXRaise
//                                     both       record cleared before each AXRaise, of B1
//                                                then C1
//                                     once       record cleared once, AXRaise B1 then C1
//                                   It reads where B1 and C1 stand against W in the on-screen
//                                   order at once, 0.3 s and 1 s later, the front process, the
//                                   key focus process, the front app's focused window and the
//                                   children's own key windows. 10 trials by default. The end,
//                                   Ctrl-C included, sets the record back to W and quits the
//                                   children. Needs Accessibility for the terminal.
import AppKit
import CKosmos

/// Each case of a trial, in the order they run.
private enum RaiseCase: String, CaseIterable {
    case control, clear, own, still, both, once
}

@MainActor func floatRaise(trials: Int) -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let probe = FloatRaise()
    floatRaiseCleanup = probe.finish
    signal(SIGINT) { _ in DispatchQueue.main.async { MainActor.assumeIsolated { floatRaiseCleanup?(); exit(130) } } }
    probe.run(trials: max(trials, 1))
    probe.finish()
    exit(0)
}

@MainActor private var floatRaiseCleanup: (() -> Void)?

@MainActor private final class FloatRaise {
    let b = Child(["raise-stub", "accessory", "0,0"])
    let c = Child(["raise-stub", "prohibited", "60,40"])
    let b1: UInt32, c1: UInt32
    let frontPid: pid_t
    /// The front app's frontmost window at the normal level, when it has one on screen.
    let w: UInt32?
    private var finished = false

    init() {
        b1 = b.readWindows().first ?? 0
        c1 = c.readWindows().first ?? 0
        let frontPid = kosmos_front_pid()
        self.frontPid = frontPid
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))   // the children's windows reach the screen
        w = FloatRaise.order().first { $0.pid == frontPid }?.id
        let name = NSRunningApplication(processIdentifier: frontPid)?.localizedName ?? "?"
        print("B1 \(b1) (pid \(b.pid)), C1 \(c1) (pid \(c.pid)); front process \(name) (\(frontPid)), W \(w.map(String.init) ?? "none")")
    }

    func run(trials: Int) {
        var above: [RaiseCase: [Int]] = [:]
        for trial in 1...trials {
            for raiseCase in RaiseCase.allCases {
                prepare()
                let start = ContinuousClock.now
                switch raiseCase {
                case .control: raise(b, b1)
                case .clear: SLSSetFrontWindow(SLSMainConnectionID(), 0); raise(b, b1)
                case .own: SLSSetFrontWindow(SLSMainConnectionID(), b1); raise(b, b1)
                case .still: SLSSetFrontWindow(SLSMainConnectionID(), 0)
                case .both:
                    SLSSetFrontWindow(SLSMainConnectionID(), 0); raise(b, b1)
                    SLSSetFrontWindow(SLSMainConnectionID(), 0); raise(c, c1)
                case .once: SLSSetFrontWindow(SLSMainConnectionID(), 0); raise(b, b1); raise(c, c1)
                }
                let ms = elapsed(start)
                var line = String(format: "trial %d %-8@ %.2f ms:", trial, raiseCase.rawValue as NSString, ms)
                for (index, wait) in [0.0, 0.3, 0.7].enumerated() {
                    settle(wait)
                    let reading = read()
                    line += " [\(["now", "0.3s", "1s"][index]) \(reading.text)]"
                    if index == 2, reading.b1AboveW { above[raiseCase, default: []].append(trial) }
                }
                print(line)
            }
        }
        print("\nB1 above W at 1 s:")
        for raiseCase in RaiseCase.allCases { print("  \(raiseCase.rawValue): \(above[raiseCase]?.count ?? 0) of \(trials)") }
    }

    /// Both children's windows to the back of the normal level, and the record to W.
    func prepare() {
        b.send("back"); _ = b.line()
        c.send("back"); _ = c.line()
        SLSSetFrontWindow(SLSMainConnectionID(), w ?? 0)
        settle(0.1)
    }

    func raise(_ child: Child, _ window: UInt32) {
        guard let element = windowElement(child.pid, window) else { return print("  no element for \(window)") }
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if result != .success { print("  AXRaise of \(window) returned \(result.rawValue)") }
    }

    struct Reading {
        let text: String
        let b1AboveW: Bool
    }

    func read() -> Reading {
        let order = FloatRaise.order()
        func index(_ id: UInt32?) -> Int? { id.flatMap { id in order.firstIndex { $0.id == id } } }
        let ib = index(b1), ic = index(c1), iw = index(w)
        let front = kosmos_front_pid(), keyFocus = kosmos_key_focus_pid()
        let focused = focusedWindow(of: frontPid)
        b.send("key"); let bKey = b.line()
        c.send("key"); let cKey = c.line()
        let place = "B1 #\(ib.map(String.init) ?? "-") C1 #\(ic.map(String.init) ?? "-") W #\(iw.map(String.init) ?? "-")"
        let focus = "front \(front == frontPid ? "same" : String(front)) keyfocus \(keyFocus) W-app focused \(focused.map(String.init) ?? "none")"
        let text = "\(place); \(focus); B key \(bKey) C key \(cKey)"
        return Reading(text: text, b1AboveW: ib != nil && iw != nil && ib! < iw!)
    }

    /// The on-screen windows at the normal level, front first.
    static func order() -> [(id: UInt32, pid: pid_t)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0, let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            return (UInt32(id), pid_t(pid))
        }
    }

    func settle(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    func finish() {
        guard !finished else { return }
        finished = true
        SLSSetFrontWindow(SLSMainConnectionID(), w ?? 0)
        b.terminate()
        c.terminate()
    }
}

/// A 120 by 90 window at an "x,y" offset from the bottom left of the built-in display's visible
/// frame, in an app that is never front. Answers "back" (orderBack:), and "key" with the
/// window AppKit holds key, or 0. Exits when its standard input closes.
@MainActor func raiseStub(_ arguments: [String]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(arguments.first == "prohibited" ? .prohibited : .accessory)
    let origin = builtInScreen().visibleFrame.origin
    let xy = (arguments.dropFirst().first ?? "0,0").split(separator: ",").compactMap { Double($0) }
    let window = NSWindow(contentRect: NSRect(x: origin.x + 20 + xy[0], y: origin.y + 20 + xy[1], width: 120, height: 90),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "kosmos-probe float-raise"
    window.backgroundColor = arguments.first == "prohibited" ? .systemRed : .systemBlue
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    print(window.windowNumber)
    Thread.detachNewThread {
        while let line = readLine() {
            let reply: String = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    switch line {
                    case "back": window.orderBack(nil); return "ok"
                    case "key": return String(NSApp.keyWindow?.windowNumber ?? 0)
                    default: return "?"
                    }
                }
            }
            print(reply)
        }
        exit(0)
    }
    app.run()
    exit(0)
}
