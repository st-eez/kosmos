// The windows and readings script/bench-relayout.sh uses.
//
//   kosmos-probe bench-windows <count> [display]
//                                   Windows for script/bench-relayout.sh, which runs this from
//                                   a bundle so macOS takes it for a regular app from launch
//                                   and a running Kosmos tiles them. Opens count standard
//                                   windows, titled and resizable, on the display of that
//                                   name as `kosmos state` gives it, else the main one, and
//                                   never activates the app. Launch it with `open -g`, as the
//                                   script does: run directly from a terminal, it became the
//                                   front app as its first window opened (key-holder, on
//                                   2026-09-25), and with no window it did not. Prints the
//                                   windows' ids on one line, then `frame <id> <x> <y> <w>
//                                   <h> <time>` at each new frame, with Kosmos's coordinates
//                                   and the wall clock that bash's EPOCHREALTIME reads. Lines
//                                   on stdin: `close <id>` closes a window, and `open` opens
//                                   one where the last closed one was and prints `opened <id>
//                                   <time>`. Quits at the end of stdin.
//   kosmos-probe eui [pid...]       AXEnhancedUserInterface of each running regular app, or of
//                                   the apps given, as `<pid> <name>: on|off|unsupported`.
//                                   While it is on, Chrome and Firefox animate each
//                                   Accessibility move themselves; VoiceOver turns it on.
//                                   Read only: one read per app, with a 0.5 s timeout. Needs
//                                   Accessibility for the terminal.
import AppKit

@MainActor func benchWindows(_ count: Int, on display: String?) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let screen = NSScreen.screens.first { $0.localizedName == display } ?? NSScreen.main ?? NSScreen.screens[0]
    let area = screen.visibleFrame
    let bench = BenchWindows()
    let ids = (0..<count).map { index in
        let step = 30 * CGFloat(index)
        return bench.open(NSRect(x: area.minX + 40 + step, y: area.maxY - 340 - step, width: 480, height: 300))
    }
    print(ids.map(String.init).joined(separator: " "))
    Thread.detachNewThread {
        while let line = readLine() {
            let words = line.split(separator: " ")
            if words == ["open"] {
                DispatchQueue.main.async { MainActor.assumeIsolated { if let id = bench.reopen() { print("opened \(id) \(epochNow())") } } }
            } else if words.count == 2, words[0] == "close", let id = Int(words[1]) {
                DispatchQueue.main.async { MainActor.assumeIsolated { bench.close(id) } }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// The wall clock in seconds, to the microsecond, as bash's EPOCHREALTIME prints it.
func epochNow() -> String { String(format: "%.6f", Date().timeIntervalSince1970) }

/// The windows of `bench-windows`. Each prints its frame when it moves or resizes, once per
/// new frame, with the origin at the top left of the main display, as Kosmos logs frames.
@MainActor final class BenchWindows: NSObject, NSWindowDelegate {
    private var windows: [Int: NSWindow] = [:]
    private var printed: [Int: NSRect] = [:]
    private var closed: NSRect?
    private let top = NSScreen.screens[0].frame.maxY

    /// Orders the window in without making it key, so the app stays in the background.
    func open(_ frame: NSRect) -> Int {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "kosmos-probe bench"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.orderFrontRegardless()
        windows[window.windowNumber] = window
        return window.windowNumber
    }

    /// The window goes when its last reference does, which destroys it in WindowServer.
    func close(_ id: Int) {
        guard let window = windows.removeValue(forKey: id) else { return }
        printed[id] = nil
        closed = window.frame
        window.close()
    }

    func reopen() -> Int? { closed.map(open) }

    func windowDidMove(_ notification: Notification) { printFrame(notification) }
    func windowDidResize(_ notification: Notification) { printFrame(notification) }

    private func printFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = window.windowNumber, frame = window.frame
        guard printed[id] != frame else { return }
        printed[id] = frame
        print("frame \(id) \(Int(frame.minX)) \(Int(top - frame.maxY)) \(Int(frame.width)) \(Int(frame.height)) \(epochNow())")
    }
}

@MainActor func enhancedUserInterface(_ pids: [pid_t]) {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let apps = pids.isEmpty
        ? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        : pids.compactMap { NSRunningApplication(processIdentifier: $0) }
    for app in apps {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXEnhancedUserInterface" as CFString, &value)
        let state = switch error {
        case .success: (value as? Bool).map { $0 ? "on" : "off" } ?? "not a boolean"
        case .attributeUnsupported, .noValue: "unsupported"
        default: "no answer, error \(error.rawValue)"
        }
        print("\(app.processIdentifier) \(app.localizedName ?? "?"): \(state)")
    }
}
