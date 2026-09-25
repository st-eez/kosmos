// Windows that leave and come back: native fullscreen, the key window's departure, and native
// tabs (docs/tree.md).
//
//   kosmos-probe fullscreen [dry]   Which signals report a window entering and leaving
//                                   native fullscreen, and when: SkyLight Space events, and
//                                   Displays.isFullscreen after each Space membership event,
//                                   as the inventory checks it. dry never enters.
//   kosmos-probe departures         When the key window leaves, which does macOS report
//                                   first: the window leaving (ordered out or destroyed) or
//                                   the next key window? Minimizes, closes and hides a
//                                   window of its own accessory app, with one clock, and
//                                   minimizes the app's last window, after which macOS may
//                                   report no key window at all, and keys another window
//                                   during a minimize's animation.
//                                   The window belongs to an accessory app, which Kosmos
//                                   does not manage.
//   kosmos-probe tabs [strip|keep]  Does WindowServer order out the deselected window of a
//                                   native tab group, and which Spaces keep it? Two tabs of
//                                   its own, invisible and off every display, in an app with
//                                   the prohibited activation policy, switched twice. strip
//                                   or keep conceals the selected tab in a holding Space
//                                   first, as Kosmos does, to see whether deselecting it
//                                   drops that membership. Each event prints the tab's
//                                   frame: tab B joins at another size, and the selected
//                                   tab's frame changes 0.3 s before a switch, then just
//                                   before one.
//                                   Accessibility focus changes print only when the
//                                   terminal is trusted.
import AppKit
import CKosmos
import KosmosSkyLight

/// A window that enters native fullscreen 1.5 s after it appears and leaves 4 s later, in
/// an accessory app. Prints its window id.
@MainActor func fullscreenWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 300),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.collectionBehavior = [.fullScreenPrimary]
    window.title = "kosmos-probe fullscreen"
    window.makeKeyAndOrderFront(nil)
    app.activate()
    print(window.windowNumber)
    let dry = CommandLine.arguments.contains("dry")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { print("enter"); if !dry { window.toggleFullScreen(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { print("leave"); if !dry { window.toggleFullScreen(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
    app.run()
    exit(0)
}

@MainActor func fullscreen() -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let child = Child(["fullscreen-window"] + (CommandLine.arguments.contains("dry") ? ["dry"] : []))
    let window = child.readWindows()[0]
    let start = ContinuousClock.now
    print("window \(window), pid \(child.pid)")
    child.onLines { print(String(format: "%7.1f ms child: ", elapsed(start)) + $0) }
    WindowServerEvent.register([1325, 1326, 1327, 1328, 1401, 806, 807, 808, 815, 816]) { id, named, payload in
        let space = payload.count >= 8 ? payload.loadUnaligned(as: UInt64.self) : 0
        switch id {
        case 1325, 1326:
            guard named == window else { return }
            print(String(format: "%7.1f ms event %d space %llu", elapsed(start), id, space))
            // The check the inventory makes on these events, off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let state = Displays.isFullscreen(window).map { "\($0)" } ?? "nil (no Space)"
                print(String(format: "%7.1f ms   Displays.isFullscreen: ", elapsed(start)) + state)
            }
        case 1327, 1328:
            print(String(format: "%7.1f ms event %d space %llu", elapsed(start), id, space))
        case 1401:
            print(String(format: "%7.1f ms event 1401", elapsed(start)))
        default:
            guard named == window else { return }
            print(String(format: "%7.1f ms event %d", elapsed(start), id))
        }
    }
    SkyLight.watch([window])
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    app.run()
    exit(0)
}

/// Two windows of an accessory app. The first is minimized and restored. It is minimized
/// again while the second is keyed during the animation: does macOS still key a window
/// when the animation ends? The first is restored and closed. The second, the app's last
/// window, is minimized and restored: does macOS report any key window then, or does the
/// app stay front with none? Then the app hides. Each key change is printed with its
/// uptime.
@MainActor func departuresWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func window(_ x: CGFloat, _ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 160, width: 320, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }
    let other = window(140, "kosmos-probe B"), first = window(500, "kosmos-probe A")
    other.makeKeyAndOrderFront(nil)
    first.makeKeyAndOrderFront(nil)
    app.activate()
    print("\(first.windowNumber) \(other.windowNumber)")
    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated { print(String(format: "%.1f child: key %d", uptime(), window?.windowNumber ?? 0)) }
    }
    let say = { (text: String) in print(String(format: "%.1f child: ", uptime()) + text) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { say("minimize A"); first.miniaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { say("restore A"); first.deminiaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { say("minimize A"); first.miniaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { say("key B during the animation"); other.makeKeyAndOrderFront(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { say("restore A"); first.deminiaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { say("close A"); first.close() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { say("minimize B, the last window"); other.miniaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { say("restore B"); other.deminiaturize(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) { say("hide app"); app.hide(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { exit(0) }
    app.run()
    exit(0)
}

@MainActor func departures() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let child = Child(["departures-window"])
    let ids = child.readWindows()
    print("windows A \(ids[0]) B \(ids[1]), pid \(child.pid)")
    child.onLines { print($0) }
    WindowServerEvent.register([804, 806, 807, 808, 815, 816, 1325, 1326]) { id, window, _ in
        guard let window, ids.contains(window) else { return }
        print(String(format: "%.1f event %d window %d", uptime(), id, window))
    }
    SkyLight.watch(ids)
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                 NSWorkspace.didDeactivateApplicationNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let short = name.rawValue.replacingOccurrences(of: "NSWorkspace", with: "").replacingOccurrences(of: "ApplicationNotification", with: "")
            print(String(format: "%.1f workspace %@ %@", uptime(), short, app?.localizedName ?? "?"))
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 13) { exit(0) }
    app.run()
    exit(0)
}

/// Two windows in one native tab group, invisible and off every display. Prints both
/// window ids, then selects each tab in turn, printing each selection with its uptime.
@MainActor func tabsWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    func window(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "kosmos-probe-tabs"
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        return window
    }
    let first = window("kosmos-probe tab A"), second = window("kosmos-probe tab B")
    // B starts at another size, to see whether joining the group gives it A's frame.
    second.setFrame(NSRect(x: -4000, y: -4000, width: 420, height: 260), display: false)
    first.orderFrontRegardless()
    first.addTabbedWindow(second, ordered: .above)
    second.orderFrontRegardless()
    print("\(first.windowNumber) \(second.windowNumber)")
    let say = { (text: String) in print(String(format: "%.1f child: ", uptime()) + text) }
    // A frame written to the selected tab alone, as Kosmos writes one: does the next tab
    // selected come in with it?
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        say("B's frame set to 520x330")
        second.setFrame(NSRect(x: -4100, y: -4100, width: 520, height: 330), display: false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { say("select A"); first.tabGroup?.selectedWindow = first }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { say("select B"); first.tabGroup?.selectedWindow = second }
    // A frame set on the selected tab just before the switch, in the same turn.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        say("B's frame set to 600x360, then select A")
        second.setFrame(NSRect(x: -4200, y: -4200, width: 600, height: 360), display: false)
        first.tabGroup?.selectedWindow = first
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    app.run()
    exit(0)
}

nonisolated(unsafe) var tabWindows: [UInt32] = []

@MainActor func tabs(conceal: String?) -> Never {
    // SkyLight delivers events inside a running AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let child = Child(["tabs-window"])
    tabWindows = child.readWindows()
    print("tab A \(tabWindows[0]), tab B \(tabWindows[1]), selected B")
    child.onLines { print($0) }
    // 1325 and 1326: a window joins or leaves a Space; 815 and 816: ordered in or out.
    WindowServerEvent.register([815, 816, 1325, 1326]) { id, window, _ in
        guard let window, tabWindows.contains(window) else { return }
        // The frame the inventory reads when this event reaches it.
        let frame = SkyLight.rows([window]).first.map { "\($0.frame)" } ?? "no row"
        print(String(format: "%.1f event %d tab %@ frame %@", uptime(), id, window == tabWindows[0] ? "A" : "B", frame))
    }
    SkyLight.watch(tabWindows)
    // The child's focused window as Accessibility reports it, only when trusted: the probe
    // never asks for the permission.
    var observer: AXObserver?
    if AXIsProcessTrusted(), AXObserverCreate(child.pid, { _, element, _, _ in
        var id: UInt32 = 0
        _ = _AXUIElementGetWindow(element, &id)
        print(String(format: "%.1f AX focused window tab %@", uptime(), id == tabWindows[0] ? "A" : id == tabWindows[1] ? "B" : "\(id)"))
    }, &observer) == .success, let observer {
        AXObserverAddNotification(observer, AXUIElementCreateApplication(child.pid),
                                  kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        print("Accessibility trusted: focus changes print (none while the child cannot be key)")
    } else {
        print("Accessibility not trusted: no focus changes")
    }
    // Conceal the selected tab as Kosmos does, stripping its ordinary Space or keeping it.
    var space: UInt64 = 0
    if conceal == "strip" || conceal == "keep" {
        space = kosmos_holding_create()
        var ids = [tabWindows[1]]
        kosmos_add_windows(space, &ids, 1, conceal == "strip")
        _ = kosmos_barrier(space)
        print("B concealed (\(conceal!)) in holding Space \(space)")
    }
    /// Each tab's order and Spaces as the inventory reads them, and holding membership.
    func state(_ step: String) {
        let rows = Dictionary(uniqueKeysWithValues: SkyLight.rows(tabWindows).map { ($0.id, $0) })
        if space != 0 { _ = kosmos_barrier(space) }
        let parts = zip(["A", "B"], tabWindows).map { name, id in
            let spaces = SkyLight.spaces(of: id) ?? []
            let held = space != 0 ? ", in holding \(inSpace(id, space))" : ""
            return "\(name) ordered in \(rows[id].map { "\($0.orderedIn)" } ?? "no row") frame \(rows[id].map { "\($0.frame)" } ?? "none") Spaces \(spaces)" + held
        }
        print(String(format: "%.1f ", uptime()) + step + ": " + parts.joined(separator: ", "))
    }
    func finish() -> Never {
        if space != 0 {
            var ids = tabWindows
            kosmos_remove_windows(space, &ids, Int(ids.count))
            kosmos_space_destroy(space)
        }
        child.terminate()
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { state("B selected") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { state("after select A") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { state("after select B") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { state("after the frame change and select A") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { finish() }
    app.run()
    exit(0)
}
