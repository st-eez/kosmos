// Whether Kosmos can tell the user's own input from input another process posts, and which
// app the input went to, so a follow can be tied to what the user did (docs/focus.md).
//
//   kosmos-probe input-source [seconds] [hid]
//                                   A listen-only tap at the annotated session location
//                                   records each key down, mouse down and flags change: its
//                                   source process and source state, and its target process,
//                                   never a key code. First for `seconds`, 20 by default, the
//                                   user's own input. Then a child posts key and mouse events
//                                   to this probe's process alone (postToPid) from a source
//                                   of each state, one with its source process set to 0 before
//                                   the post. With `hid`, a non-activating panel of the
//                                   probe's own goes under the pointer at screen saver level,
//                                   and the child posts a left click at the panel's center
//                                   through the HID location, then through the session
//                                   location, so only the panel gets it; skipped while a
//                                   mouse button or modifier is down. Prints what the tap
//                                   saw of each, what reached the probe, and whether each
//                                   state's last key down and left mouse down clocks moved.
//                                   Sends nothing to any other app's window.
import AppKit

private struct InputSeen {
    let type: CGEventType
    let at: Double
    let sourcePID: Int64
    let sourceState: Int64
    let targetPID: Int64
    let userData: Int64
}

@MainActor private var seen: [InputSeen] = []
@MainActor private var arrived: [String] = []

private let posterUserData: Int64 = 0x4b6f736d   // "Kosm", marks the child's events

private func clocks() -> String {
    func age(_ state: CGEventSourceStateID, _ type: CGEventType) -> String {
        String(format: "%.3f", CGEventSource.secondsSinceLastEventType(state, eventType: type))
    }
    return "key down hid \(age(.hidSystemState, .keyDown)) s, combined \(age(.combinedSessionState, .keyDown)) s; "
        + "left mouse down hid \(age(.hidSystemState, .leftMouseDown)) s, combined \(age(.combinedSessionState, .leftMouseDown)) s"
}

private func name(_ type: CGEventType) -> String {
    switch type {
    case .keyDown: "key down"
    case .flagsChanged: "flags changed"
    case .leftMouseDown: "left mouse down"
    case .rightMouseDown: "right mouse down"
    case .otherMouseDown: "other mouse down"
    default: "type \(type.rawValue)"
    }
}

private func appName(_ pid: Int64) -> String {
    pid == 0 ? "none" : NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "pid \(pid)"
}

private func summarize(_ events: [InputSeen], _ title: String) {
    print("\(title): \(events.count) events")
    var groups: [String: Int] = [:]
    for event in events {
        let key = "\(name(event.type)): source pid \(event.sourcePID) (\(appName(event.sourcePID))), source state \(event.sourceState), "
            + "target \(appName(event.targetPID))\(event.userData == posterUserData ? ", the child's" : "")"
        groups[key, default: 0] += 1
    }
    for (key, count) in groups.sorted(by: { $0.key < $1.key }) { print("  \(count) x \(key)") }
}

private final class ClickView: NSView {
    override func mouseDown(with event: NSEvent) {
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        MainActor.assumeIsolated { arrived.append("panel got a mouse down, source pid \(source)") }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor func inputSource(seconds: Double, hid: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    print("Input Monitoring granted: \(CGPreflightListenEventAccess()), posting granted: \(CGPreflightPostEventAccess())")
    let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    guard let port = CGEvent.tapCreate(
        tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue },
        callback: { _, type, event, _ in
            let record = InputSeen(type: type, at: uptime(),
                              sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                              sourceState: event.getIntegerValueField(.eventSourceStateID),
                              targetPID: event.getIntegerValueField(.eventTargetUnixProcessID),
                              userData: event.getIntegerValueField(.eventSourceUserData))
            MainActor.assumeIsolated { seen.append(record) }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else {
        print("tap not created")
        exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        arrived.append("probe got a \(event.type == .keyDown ? "key down" : "left mouse down"), source pid \(source)")
        return event
    }
    print("recording the user's own input for \(seconds) s; \(clocks())")

    func runChild(_ arguments: [String]) -> (start: Double, end: Double) {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["input-poster", String(getpid())] + arguments
        let start = uptime()
        try! child.run()
        child.waitUntilExit()
        return (start, uptime())
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        summarize(seen, "the user's input")
        let before = seen.count
        print("before the child: \(clocks())")
        let pid = runChild(["pid"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            print("after the child's posts to this process (\(String(format: "%.0f", pid.end - pid.start)) ms): \(clocks())")
            summarize(Array(seen[before...]), "seen by the tap during and after them")
            print("arrived: \(arrived.isEmpty ? "nothing" : arrived.joined(separator: "; "))")
            guard hid else { exit(0) }
            arrived = []
            guard NSEvent.pressedMouseButtons == 0, CGEventSource.flagsState(.hidSystemState).intersection(
                [.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty else {
                print("a mouse button or modifier is down: the click through the HID location is skipped")
                exit(0)
            }
            let pointer = NSEvent.mouseLocation
            let panel = NSPanel(contentRect: NSRect(x: pointer.x - 20, y: pointer.y - 20, width: 40, height: 40),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = NSColor.white.withAlphaComponent(0.02)
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.contentView = ClickView()
            panel.orderFrontRegardless()
            // CG coordinates have their origin at the top left of the primary display.
            let primary = NSScreen.screens[0].frame.height
            let center = CGPoint(x: pointer.x, y: primary - pointer.y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Only the panel may get the clicks.
                guard NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == panel.windowNumber else {
                    print("the panel is not the top window at \(pointer): the clicks are skipped")
                    exit(0)
                }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let before = seen.count
                print("panel \(panel.windowNumber) at \(center); front app \(front); before: \(clocks())")
                let click = runChild(["hid", "\(center.x)", "\(center.y)"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("after the clicks (\(String(format: "%.0f", click.end - click.start)) ms): \(clocks()); "
                          + "front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    summarize(Array(seen[before...]), "seen by the tap during and after them")
                    print("arrived: \(arrived.isEmpty ? "nothing" : arrived.joined(separator: "; "))")
                    panel.orderOut(nil)
                    exit(0)
                }
            }
        }
    }
    app.run()
    exit(0)
}

/// Posts to `parent` alone, or with `hid` a left click at a point the parent's panel covers.
func inputPoster(parent: pid_t, mode: String, point: CGPoint?) -> Never {
    func stamp(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUserData, value: posterUserData)
        return event
    }
    switch mode {
    case "pid":
        // F19, which nothing binds, to the parent only.
        for state in [CGEventSourceStateID.hidSystemState, .combinedSessionState, .privateState] {
            let source = CGEventSource(stateID: state)
            for down in [true, false] {
                stamp(CGEvent(keyboardEventSource: source, virtualKey: 80, keyDown: down)!).postToPid(parent)
            }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                stamp(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: -10000, y: -10000),
                              mouseButton: .left)!).postToPid(parent)
            }
            usleep(20_000)
        }
        let forged = stamp(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 80, keyDown: true)!)
        forged.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        forged.postToPid(parent)
        stamp(CGEvent(keyboardEventSource: nil, virtualKey: 80, keyDown: false)!).postToPid(parent)
    case "hid":
        guard let point else { exit(2) }
        for (tap, state) in [(CGEventTapLocation.cghidEventTap, CGEventSourceStateID.hidSystemState),
                             (.cgSessionEventTap, .combinedSessionState)] {
            let source = CGEventSource(stateID: state)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                stamp(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!)
                    .post(tap: tap)
            }
            usleep(150_000)
        }
    default:
        exit(2)
    }
    usleep(50_000)
    exit(0)
}
