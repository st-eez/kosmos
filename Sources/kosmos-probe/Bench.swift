// The windows and readings script/bench-relayout.sh and script/bench-frames.sh use
// (docs/geometry.md).
//
//   kosmos-probe bench-windows <count> [display] [--colors]
//                                   Opens count windows on the display of that name, as
//                                   `kosmos state` gives it, else the main one, and prints
//                                   their ids, then `frame <id> <x> <y> <w> <h> <time>` at each
//                                   new frame, in Kosmos's coordinates with EPOCHREALTIME's
//                                   clock. On stdin, `close <id>` closes a window, `open` opens
//                                   one where the last closed one was and `new` one in the
//                                   middle of the display that takes the key, each printing
//                                   `opened <id> <time>`, and `hide <id>` orders a window out
//                                   and `show <id>` in again. With --colors each window is one
//                                   color of KosmosBench's palette, a color no other open window
//                                   has, with no shadow and no title, and `color <id> <index>
//                                   <time>` names it. Run it from a bundle with `open -g`, as the
//                                   scripts do: run from a terminal, it becomes the front app.
//   kosmos-probe eui [pid...]       AXEnhancedUserInterface of each running regular app, or of
//                                   the apps given. While it is on, Chrome and Firefox animate
//                                   their own Accessibility moves. Read only. Needs
//                                   Accessibility for the terminal.
import AppKit
import KosmosBench

@MainActor func benchWindows(_ count: Int, on display: String?, colors: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let screen = NSScreen.screens.first { $0.localizedName == display } ?? NSScreen.main ?? NSScreen.screens[0]
    let area = screen.visibleFrame
    let bench = BenchWindows(colors: colors)
    let ids = (0..<count).map { index in
        let step = 30 * CGFloat(index)
        return bench.open(NSRect(x: area.minX + 40 + step, y: area.maxY - 340 - step, width: 480, height: 300))
    }
    print(ids.map(String.init).joined(separator: " "))
    Thread.detachNewThread {
        let middle = NSRect(x: area.midX - 240, y: area.midY - 150, width: 480, height: 300)
        while let line = readLine() {
            let words = line.split(separator: " ")
            let id = words.count == 2 ? Int(words[1]) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch (words.first, id) {
                    case ("open", nil): if let id = bench.reopen() { print("opened \(id) \(epochNow())") }
                    case ("new", nil): print("opened \(bench.open(middle, key: true)) \(epochNow())")
                    case let ("close", id?): bench.close(id)
                    case let ("hide", id?): bench.hide(id)
                    case let ("show", id?): bench.show(id)
                    default: break
                    }
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

/// The wall clock in seconds, to the microsecond, as bash's EPOCHREALTIME prints it.
func epochNow() -> String { String(format: "%.6f", Date().timeIntervalSince1970) }

@MainActor final class BenchWindows: NSObject, NSWindowDelegate {
    private let colors: Bool
    private var windows: [Int: NSWindow] = [:]
    private var colored: [Int: Int] = [:]
    private var printed: [Int: NSRect] = [:]
    private var closed: NSRect?
    private let top = NSScreen.screens[0].frame.maxY

    init(colors: Bool) { self.colors = colors }

    /// Orders the window in without making it key, so the app stays in the background, unless
    /// `key` asks for the key as an app's new window takes it.
    func open(_ frame: NSRect, key: Bool = false) -> Int {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if colors { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "kosmos-probe bench"
        window.isReleasedWhenClosed = false
        window.delegate = self
        if colors, let color = Palette.stub.colors.indices.first(where: { !colored.values.contains($0) }) {
            // The whole frame in one color, so KosmosBench finds the window by it.
            let (red, green, blue) = Color.components(Palette.stub.colors[color])
            window.backgroundColor = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.hasShadow = false
            // AppKit's own fade and zoom as a window opens or closes would show as Kosmos's.
            window.animationBehavior = .none
            colored[window.windowNumber] = color
            print("color \(window.windowNumber) \(color) \(epochNow())")
        }
        if key { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        windows[window.windowNumber] = window
        return window.windowNumber
    }

    /// The window goes when its last reference does, which destroys it in WindowServer.
    func close(_ id: Int) {
        guard let window = windows.removeValue(forKey: id) else { return }
        printed[id] = nil
        colored[id] = nil
        closed = window.frame
        window.close()
    }

    func reopen() -> Int? { closed.map { open($0) } }

    /// Ordered out, the app keeps the window, as one closed and kept (docs/tree.md).
    func hide(_ id: Int) { windows[id]?.orderOut(nil) }

    func show(_ id: Int) { windows[id]?.orderFrontRegardless() }

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
