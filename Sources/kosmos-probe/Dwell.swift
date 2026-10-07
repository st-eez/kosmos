// Whether a Space under the desktop Space holds real apps' windows drawn and capturable for
// minutes, as the agent workspace would while no display shows it (docs/hiding.md).
//
//   kosmos-probe dwell [minutes] [textedit|chrome|calculator...] [workspace=<name>]
//                                   Opens each app's window as `kosmos-probe peek` does, lets
//                                   Kosmos conceal it on a hidden workspace, then moves it from
//                                   Kosmos's holding Space into one Space of the probe's, one
//                                   level under the desktop Space of that workspace's display,
//                                   stripped of its ordinary Space, at alpha 1, for 5 minutes
//                                   unless given. TextEdit and Calculator by default. Every 10 s
//                                   it reads, for each window: its Spaces, whether the window
//                                   list keeps the desktop picture over it, the hit test at its
//                                   center, a ScreenCaptureKit capture judged as `peek` judges
//                                   one, and every minute CuaDriver's screenshot. Calculator
//                                   gets pixel clicks through CuaDriver, AC 4 + 2 =, grounded on
//                                   a fresh screenshot each, at the start, the middle and the
//                                   end, its display read back through Accessibility. It logs
//                                   app activations, Space changes, sleep, wake and the session
//                                   leaving and coming back, with the windows' state then, so
//                                   Steve can Command-Tab, click the Dock, switch workspaces or
//                                   lock the screen during it. A window whose workspace Kosmos
//                                   shows leaves the probe's Space, as Kosmos revealed it. A
//                                   window the window list puts over the desktop picture turns
//                                   the Space to alpha 0 and ends the dwell. Ctrl-C or the end
//                                   puts the windows back in Kosmos's holding Space, quits the
//                                   apps and destroys the Space.
import AppKit
import CKosmos
import CKosmosSweep
import KosmosSkyLight

private let dwellTick = 10.0
private let cuaPath = NSHomeDirectory() + "/.local/bin/cua-driver"
private let cuaSession = "kosmos-probe-dwell"

/// Runs a command and returns its exit status and standard output alone, for JSON.
private func runQuiet(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

private func cua(_ tool: String, _ arguments: [String: Any]) -> [String: Any]? {
    var arguments = arguments
    arguments["session"] = cuaSession
    guard let data = try? JSONSerialization.data(withJSONObject: arguments) else { return nil }
    let (_, output) = runQuiet(cuaPath, ["call", tool, String(decoding: data, as: UTF8.self)])
    return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        ?? ["error": output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)]
}

/// Where the window list puts the window against the desktop pictures over its frame.
private func order(of window: UInt32, at frame: CGRect) -> (onScreen: Bool, underPicture: Bool, text: String) {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    guard let own = list.firstIndex(where: { $0[kCGWindowNumber as String] as? UInt32 == window }) else {
        return (false, false, "off the on-screen list")
    }
    let pictures = list.indices.filter { index in
        let bounds = (list[index][kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        return list[index][kCGWindowName as String] as? String == "Wallpaper" && bounds?.contains(frame) == true
    }
    let under = pictures.contains { $0 < own }
    return (true, under, "at \(own) of \(list.count), desktop pictures at \(pictures)")
}

@MainActor private func hit(_ point: CGPoint) -> Int {
    NSWindow.windowNumber(at: NSPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y), belowWindowWithWindowNumber: 0)
}

/// Every element under `element` to a depth, breadth first.
private func axAll(_ element: AXUIElement, depth: Int = 10) -> [AXUIElement] {
    var all: [AXUIElement] = [], level = [element]
    for _ in 0..<depth where !level.isEmpty {
        all += level
        level = level.flatMap { axCopy($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    }
    return all
}

/// Calculator's button for a key: its description, identifier or title names it.
private func calculatorButton(_ window: AXUIElement, _ names: [String]) -> AXUIElement? {
    axAll(window).first { element in
        guard axCopy(element, kAXRoleAttribute) as? String == kAXButtonRole else { return false }
        let labels = [kAXDescriptionAttribute, kAXIdentifierAttribute, kAXTitleAttribute]
            .compactMap { axCopy(element, $0) as? String }.map { $0.lowercased() }
        return labels.contains { names.contains($0) }
    }
}

/// What Calculator's display shows: its static texts' values.
private func calculatorDisplay(_ window: AXUIElement) -> String {
    axAll(window).filter { axCopy($0, kAXRoleAttribute) as? String == kAXStaticTextRole }
        .compactMap { axCopy($0, kAXValueAttribute) as? String }
        .map { $0.filter { !"\u{200e}\u{200f}".contains($0) } }
        .joined(separator: " | ")
}

/// AC 4 + 2 = as pixel clicks through CuaDriver, each grounded on a fresh screenshot.
@MainActor private func pressSum(_ target: AppTarget) -> String {
    let keys: [(String, [String])] = [("AC", ["all clear", "clear", "ac", "c"]), ("4", ["4"]), ("+", ["add", "plus", "+"]),
                                      ("2", ["2"]), ("=", ["equals", "="])]
    var steps: [String] = []
    for (key, names) in keys {
        guard let button = calculatorButton(target.element, names), let frame = axFrame(button) else {
            steps.append("\(key): no button")
            return steps.joined(separator: "; ") + "; display '\(calculatorDisplay(target.element))'"
        }
        let path = NSTemporaryDirectory() + "kosmos-probe-dwell-calculator.png"
        let state = cua("get_window_state", ["pid": target.pid, "window_id": target.window, "include_accessibility_tree": false,
                                             "screenshot_out_file": path])
        guard let state, let capture = state["capture_id"] as? String, let width = state["screenshot_width"] as? Double,
              let bounds = state["window_bounds"] as? [String: Double], let windowWidth = bounds["width"], windowWidth > 0,
              let x0 = bounds["x"], let y0 = bounds["y"] else {
            steps.append("\(key): no screenshot (\(state?["error"] ?? "no answer"))")
            break
        }
        let scale = width / windowWidth
        let x = ((frame.midX - x0) * scale).rounded(), y = ((frame.midY - y0) * scale).rounded()
        let click = cua("click", ["pid": target.pid, "window_id": target.window, "x": x, "y": y, "capture_id": capture])
        // CuaDriver's answer, shortened: its error, or what it says it did.
        let answer = click.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self).prefix(160) } ?? "no answer"
        steps.append("\(key) at (\(Int(x)), \(Int(y))): \(answer)")
        pumpEvents(0.3)
    }
    return steps.joined(separator: "; ") + "; display '\(calculatorDisplay(target.element))'"
}

@MainActor private final class Dwelling {
    let target: AppTarget, app: PeekApp
    var done: String?

    init(_ target: AppTarget, _ app: PeekApp) { (self.target, self.app) = (target, app) }

    var center: CGPoint { CGPoint(x: target.rest.midX, y: target.rest.midY) }
}

@MainActor func dwell(minutes: Double, arguments: [String]) -> Never {
    var apps: [PeekApp] = [], workspace: String?
    for argument in arguments {
        if let app = PeekApp(argument), !(app.name == "Finder") {
            if case .electron = app { usage() }
            apps.append(app)
        } else if argument.hasPrefix("workspace="), argument.count > 10 {
            workspace = String(argument.dropFirst(10))
        } else {
            usage()
        }
    }
    if apps.isEmpty { apps = [.textEdit, .calculator] }
    NSApplication.shared.setActivationPolicy(.accessory)
    guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
        print("error: this terminal needs Screen Recording and Accessibility")
        exit(1)
    }
    guard let state = kosmosState(), let hidden = peekWorkspace(named: workspace, in: state) else {
        print("error: Kosmos did not answer, or " + (workspace.map { "workspace \($0) is shown or unknown" } ?? "no hidden workspace is empty"))
        exit(1)
    }
    print("the apps' windows go to workspace \(hidden), which no display shows")
    let cleanup = PeekCleanup()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { @Sendable in
        cleanup.runAll()
        print("interrupted; cleaned up")
        exit(130)
    }
    interrupt.resume()
    cleanup.add { _ = runQuiet(cuaPath, ["call", "end_session", #"{"session":"\#(cuaSession)"}"#]) }

    var dwelling: [Dwelling] = []
    for app in apps {
        guard let target = appTarget(app, on: hidden, cleanup: cleanup) else {
            cleanup.runAll()
            exit(1)
        }
        dwelling.append(Dwelling(target, app))
    }
    let screen = display(holding: dwelling[0].target.rest)
    let ordinary = Displays.current().ordinarySpace(on: screen, original: nil) ?? 0
    var ordinaryLevel: Int32 = 0
    guard kosmos_peek_space_level(ordinary, &ordinaryLevel) else {
        print("error: the level of Space \(ordinary) did not read")
        cleanup.runAll()
        exit(1)
    }
    let space = kosmos_float_space_create(ordinaryLevel - 1)
    guard space != 0 else { print("error: no Space"); cleanup.runAll(); exit(1) }
    // Transparent until the window list shows the desktop picture over every window.
    kosmos_space_set_alpha(space, 0)
    // Registered before the move; the windows go back to Kosmos's holding Spaces before the
    // Space goes and before the apps quit.
    let holdings = dwelling.map { ($0.target.window, $0.target.holding) }
    cleanup.add {
        // A window Kosmos revealed left the Space and stays where Kosmos shows it.
        for (window, holding) in holdings where inSpace(window, space) {
            var ids = [window]
            kosmos_add_windows(holding, &ids, 1, false)
            kosmos_remove_windows(space, &ids, 1)
            _ = kosmos_barrier(holding)
        }
        kosmos_space_destroy(space)
    }
    for item in dwelling {
        var ids = [item.target.window]
        kosmos_add_windows(space, &ids, 1, true)
        kosmos_remove_windows(item.target.holding, &ids, 1)
        _ = kosmos_barrier(space)
    }
    pumpEvents(0.3)
    let orders = dwelling.map { order(of: $0.target.window, at: $0.target.rest) }
    print(String(format: "Space %llu at level %d under Space %llu at level %d on display %u; ", space, ordinaryLevel - 1, ordinary, ordinaryLevel, screen)
          + zip(dwelling, orders).map { "\($0.target.name) \($1.text)" }.joined(separator: "; "))
    guard orders.allSatisfy({ $0.onScreen && $0.underPicture }) else {
        print("error: a window is not under the desktop picture; the Space stays at alpha 0")
        cleanup.runAll()
        exit(1)
    }
    kosmos_space_set_alpha(space, 1)
    let start = uptime()
    func stamp() -> String { String(format: "%6.1f s", (uptime() - start) / 1000) }

    /// One line per window: its Spaces, order, hit test and Kosmos's view of its workspace.
    func look(_ item: Dwelling) -> (line: String, showed: Bool) {
        let window = item.target.window
        let spaces = SkyLight.spaces(of: window) ?? []
        let (onScreen, under, text) = order(of: window, at: item.target.rest)
        let hitID = hit(item.center)
        let frame = rowFrame(window).map { "\($0)" } ?? "unread"
        return ("in our Space \(inSpace(window, space)), in holding \(inSpace(window, item.target.holding)), ordinary Spaces \(spaces), "
                + "\(text), hit \(hitID == Int(window) ? "the window" : "\(hitID)"), frame \(frame)",
                onScreen && !under && inSpace(window, space))
    }
    func lookAll(_ why: String) {
        for item in dwelling where item.done == nil { print("\(stamp()) \(why): \(item.target.name) \(look(item).line)") }
    }

    /// Whether Kosmos shows the workspace, read again after 200 ms when not, since its state can
    /// trail the reveal's write.
    func workspaceShown() -> Bool {
        for wait in [0.0, 0.2] {
            if wait > 0 { pumpEvents(wait) }
            if kosmosState()?.workspaces.first(where: { $0.name == hidden })?.shown == true { return true }
        }
        return false
    }
    /// Kosmos revealed the window into its display's ordinary Space; it leaves ours, as it
    /// would the agent workspace's Space.
    func reveal(_ item: Dwelling, _ how: String) {
        var ids = [item.target.window]
        print("\(stamp()) \(item.target.name): Kosmos showed workspace \(hidden) (\(how)); \(look(item).line)")
        kosmos_remove_windows(space, &ids, 1)
        item.done = "Kosmos showed its workspace at \(stamp())"
        pumpEvents(0.3)
        print("\(stamp()) \(item.target.name) after it left our Space: \(look(item).line)")
    }

    let center = NSWorkspace.shared.notificationCenter
    let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                                      NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                                      NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                                      NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
    final class Events: @unchecked Sendable { var lines: [String] = [] }
    let events = Events()
    let tokens = names.map { name in
        center.addObserver(forName: name, object: nil, queue: .main) { note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName
            let text = name.rawValue.replacingOccurrences(of: "NSWorkspace", with: "") + (app.map { " \($0)" } ?? "")
            MainActor.assumeIsolated { events.lines.append(text) }
        }
    }
    defer { tokens.forEach(center.removeObserver) }
    let distributed = DistributedNotificationCenter.default()
    let lockTokens = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map { name in
        distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.lines.append(name) }
        }
    }
    defer { lockTokens.forEach(distributed.removeObserver) }

    let total = minutes * 60_000
    let calculator = dwelling.first { if case .calculator = $0.app { true } else { false } }
    var clicksDone: Set<Int> = []
    var tick = 0, lastOrdinary = ordinary
    var stats: [String: (current: Int, all: Int)] = [:]
    var showedOnce = false
    print("\(stamp()) dwelling \(String(format: "%.1f", minutes)) min; workspace \(hidden) must stay hidden for the windows to stay")
    lookAll("start")
    while uptime() - start < total && !showedOnce && dwelling.contains(where: { $0.done == nil }) {
        let tickStart = uptime()
        while uptime() - tickStart < dwellTick * 1000 {
            pumpEvents(0.1)
            if !events.lines.isEmpty {
                let now = events.lines
                events.lines.removeAll()
                now.forEach(lookAll)
            }
            // A window over the desktop picture shows to Steve. Kosmos shows it when a switch
            // shows its workspace, as Command-Tab to its app does; else hide the Space at once.
            for item in dwelling where item.done == nil && look(item).showed {
                if workspaceShown() {
                    reveal(item, "over the desktop picture")
                    continue
                }
                kosmos_space_set_alpha(space, 0)
                print("\(stamp()) SHOWN: \(item.target.name) is over the desktop picture; the Space went to alpha 0")
                showedOnce = true
            }
            if showedOnce { break }
        }
        if showedOnce { break }
        let current = Displays.current().ordinarySpace(on: screen, original: nil) ?? 0
        if current != lastOrdinary {
            var level: Int32 = 0
            let read = kosmos_peek_space_level(current, &level)
            print("\(stamp()) the display's current Space changed from \(lastOrdinary) to \(current) at level \(read ? "\(level)" : "unread")")
            lastOrdinary = current
        }
        let shownWorkspace = kosmosState()?.workspaces.first { $0.name == hidden }?.shown
        for item in dwelling where item.done == nil {
            let target = item.target
            if shownWorkspace != false {
                reveal(item, shownWorkspace == nil ? "Kosmos's state unread" : "found at a check")
                continue
            }
            target.refresh()
            pumpEvents(0.3)
            let at = uptime()
            let (image, error, took) = captureWindow(target.window, size: nil)
            let verdict = image.map { target.judge($0, at) } ?? .failed(error ?? "no image")
            var stat = stats[target.name] ?? (0, 0)
            stat.all += 1
            if verdict.current == true { stat.current += 1 }
            stats[target.name] = stat
            var line = "\(stamp()) \(target.name): capture \(verdict) in \(Int(took)) ms; \(look(item).line)"
            if tick % 6 == 0 {
                let path = NSTemporaryDirectory() + "kosmos-probe-dwell-cua.png"
                try? FileManager.default.removeItem(atPath: path)
                let cuaStart = uptime()
                let shot = cua("get_window_state", ["pid": target.pid, "window_id": target.window, "include_accessibility_tree": false,
                                                    "screenshot_out_file": path])
                let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                let cuaImage = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                line += "; cua-driver \(cuaImage.map { "\(target.judge($0, cuaStart))" } ?? "failed: \(shot?["error"] ?? "no file")") in \(Int(uptime() - cuaStart)) ms"
            }
            print(line)
        }
        if let calculator, calculator.done == nil {
            let elapsed = uptime() - start
            for (index, due) in [0, total / 2, total - dwellTick * 1500].enumerated() where elapsed >= due && !clicksDone.contains(index) {
                clicksDone.insert(index)
                print("\(stamp()) Calculator pixel clicks: \(pressSum(calculator.target))")
                break
            }
        }
        tick += 1
    }
    let summary = stats.sorted { $0.key < $1.key }.map { "\($0.key) current in \($0.value.current) of \($0.value.all)" }
    print("\(stamp()) end: \(showedOnce ? "a window showed" : "no window showed"); \(summary.joined(separator: "; ")); "
          + dwelling.map { "\($0.target.name) \($0.done ?? "dwelt to the end")" }.joined(separator: "; "))
    cleanup.runAll()
    print("cleaned up")
    exit(0)
}
