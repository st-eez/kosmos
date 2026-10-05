// The real apps' windows `kosmos-probe peek` shows (Peek.swift, docs/hiding.md). Kosmos manages
// every regular app's standard window, and no rule leaves one out (docs/inventory.md), so the
// probe lets Kosmos conceal each window it opens on a hidden workspace and peeks it out of
// Kosmos's own holding Space. Kosmos leaves out the change events of a concealed window
// (docs/geometry.md) and checks only the windows a batch names, so a peek of a window on a
// workspace no switch touches goes unnoticed; the probe stops when that workspace is shown.
import AppKit
import CKosmos
import KosmosCore
import KosmosIPC
import KosmosRecovery
import KosmosSkyLight
import Vision

enum PeekApp {
    case chrome, finder, textEdit, electron(String)

    init?(_ argument: String) {
        switch argument {
        case "chrome": self = .chrome
        case "finder": self = .finder
        case "textedit": self = .textEdit
        case "electron": self = .electron("Obsidian")
        default:
            guard argument.hasPrefix("electron="), argument.count > 9 else { return nil }
            self = .electron(String(argument.dropFirst(9)))
        }
    }

    var name: String {
        switch self {
        case .chrome: "Chrome for Testing"
        case .finder: "Finder"
        case .textEdit: "TextEdit"
        case .electron(let name): name
        }
    }
}

func kosmosState() -> BarSnapshot? {
    guard let reply = try? IPCClient.send(["state"], socketPath: kosmosSocketPath()), reply.exitCode == 0 else { return nil }
    return try? JSONDecoder().decode(BarSnapshot.self, from: Data(reply.stdout.utf8))
}

/// The workspace named, when no display shows it, else an empty one no display shows, on the
/// focused display first, where the apps open their windows.
func peekWorkspace(named name: String?, in state: BarSnapshot) -> String? {
    if let name { return state.workspaces.first { $0.name == name && !$0.shown }?.name }
    let focused = state.workspaces.first { $0.focused }?.display
    let empty = state.workspaces.filter { !$0.shown && $0.windows.isEmpty }
    return (empty.first { $0.display == focused } ?? empty.first)?.name
}

private func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axCopy(element, kAXPositionAttribute), let size = axCopy(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: point, size: extent)
}

private struct AXWindow {
    let id: UInt32
    let element: AXUIElement
    let title: String
    let area: CGFloat
}

/// The app's standard windows that Accessibility lists, those on shown Spaces.
private func axWindows(_ pid: pid_t) -> [AXWindow] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let list = axCopy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    return list.compactMap { element in
        guard axCopy(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
        var id: UInt32 = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        let frame = axFrame(element) ?? .zero
        return AXWindow(id: id, element: element, title: axCopy(element, kAXTitleAttribute) as? String ?? "",
                        area: frame.width * frame.height)
    }
}

/// The first element of `role` under `element`, breadth first.
private func axFind(_ element: AXUIElement, role: String) -> AXUIElement? {
    var level = [element]
    for _ in 0..<8 {
        var next: [AXUIElement] = []
        for element in level {
            if axCopy(element, kAXRoleAttribute) as? String == role { return element }
            next += axCopy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        level = next
    }
    return nil
}

/// A value closures on several threads share.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func rowFrame(_ window: UInt32) -> CGRect? { SkyLight.rows([window])?.first?.frame }

/// Opens `urls` with the app, or launches it with `arguments`, without activating it.
@MainActor private func openInBackground(_ app: URL, urls: [URL] = [], arguments: [String] = [],
                                         newInstance: Bool = false) -> (NSRunningApplication?, String?) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    configuration.arguments = arguments
    configuration.createsNewApplicationInstance = newInstance
    final class Result: @unchecked Sendable {
        let lock = NSLock()
        var value: (NSRunningApplication?, String?)?
    }
    let result = Result()
    let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { app, error in
        result.lock.withLock { result.value = (app, error?.localizedDescription) }
    }
    if urls.isEmpty {
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: done)
    } else {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration, completionHandler: done)
    }
    let deadline = uptime() + 15000
    while uptime() < deadline {
        if let value = result.lock.withLock({ result.value }) { return value }
        pumpEvents(0.05)
    }
    return (nil, "no answer in 15 s")
}

/// Quits an app the probe launched, and kills it when it has not quit within 5 s.
private func quit(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    app.terminate()
    let start = uptime()
    while uptime() - start < 5000 && kill(pid, 0) == 0 { usleep(50_000) }
    if kill(pid, 0) == 0 { app.forceTerminate() }
}

/// The newest Chrome for Testing in Playwright's cache.
private func chromeForTesting() -> URL? {
    let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/ms-playwright")
    let builds = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
        .filter { $0.hasPrefix("chromium-") }
        .sorted { (Int($0.dropFirst(9)) ?? 0) > (Int($1.dropFirst(9)) ?? 0) }
    for build in builds {
        let directory = cache.appending(path: build)
        for platform in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where platform.hasPrefix("chrome-mac") {
            let app = directory.appending(path: "\(platform)/Google Chrome for Testing.app")
            if FileManager.default.fileExists(atPath: app.path) { return app }
        }
    }
    return nil
}

/// A page that draws the panel's cells, the tenths of a second since `t0` on the wall clock,
/// in a magenta box at its center, at each animation frame and every 10 ms.
private func countPage(t0: Int) -> String {
    """
    <!doctype html><title>kosmos-probe peek</title>
    <body style="margin:0;background:#fff">
    <div id=box style="position:fixed;left:50%;top:50%;width:200px;height:120px;margin:-60px 0 0 -100px;background:#f0f">
    <div id=text style="position:absolute;left:10px;top:20px;font:bold 24px monospace"></div></div>
    <script>
    const t0 = \(t0), cells = [];
    for (let i = 0; i < 18; i++) {
      const cell = document.createElement('div');
      cell.style.cssText = `position:absolute;left:${10 + i * 10}px;bottom:10px;width:10px;height:30px`;
      box.appendChild(cell);
      cells.push(cell);
    }
    function tick() {
      const count = Math.floor((Date.now() - t0) / 100) & 0xffff;
      cells.forEach((cell, i) => {
        const on = i == 0 || (i <= 16 && ((count >> (16 - i)) & 1));
        cell.style.background = on ? '#fff' : '#000';
      });
      text.textContent = count;
    }
    setInterval(tick, 10);
    (function frame() { tick(); requestAnimationFrame(frame); })();
    </script>
    """
}

/// Text Vision reads in an image, lowercased with the spaces taken out.
private func recognizedText(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

private func squeezed(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }

/// A token the probe shows in a document or a file name, other than the last one.
private func nextToken(after last: String) -> String {
    var token = last
    while token == last { token = "peek \(Int.random(in: 1000...9999))" }
    return token
}

extension Pixels {
    /// Mean levels over a 32 by 20 grid, to tell one frame from another.
    var fingerprint: [Double] {
        var sums = [Double](repeating: 0, count: 32 * 20), counts = [Double](repeating: 0, count: 32 * 20)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4, cell = (y * 20 / height) * 32 + x * 32 / width
                sums[cell] += Double(Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
                counts[cell] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    var blackShare: Double {
        var black = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where max(bytes[i], bytes[i + 1], bytes[i + 2]) < 10 { black += 1 }
        return Double(black) / Double(max(width * height, 1))
    }
}

/// A real app's window the probe opened, concealed by Kosmos on a hidden workspace.
@MainActor final class AppTarget: PeekTarget {
    let name: String
    let window: UInt32, pid: pid_t, holding: UInt64, rest: CGRect
    let captureSize: CGSize? = nil
    let judge: @Sendable (CGImage, Double) -> Verdict
    let putBack: @Sendable () -> Void
    let log: StubLog? = nil
    let signature: ((Pixels) -> Int)? = nil
    private let element: AXUIElement, workspace: String
    private let refreshing: () -> Void
    private let remembering: @Sendable (CGImage) -> Void

    init(name: String, window: UInt32, pid: pid_t, element: AXUIElement, holding: UInt64, rest: CGRect, workspace: String,
         judge: @escaping @Sendable (CGImage, Double) -> Verdict, refresh: @escaping () -> Void = {},
         remember: @escaping @Sendable (CGImage) -> Void = { _ in }) {
        (self.name, self.window, self.pid, self.element, self.holding, self.rest) = (name, window, pid, element, holding, rest)
        (self.workspace, self.judge, refreshing, remembering) = (workspace, judge, refresh, remember)
        let box = Unchecked(value: element)
        putBack = {
            var origin = rest.origin
            if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(box.value, kAXPositionAttribute as CFString, value) }
        }
    }

    func place(_ frame: CGRect) -> Bool {
        var origin = frame.origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        let error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        let start = uptime()
        while uptime() - start < 1000 {
            if let row = rowFrame(window), abs(row.minX - frame.minX) < 1, abs(row.minY - frame.minY) < 1 { return true }
            usleep(2000)
        }
        print("  \(name): the move to \(frame) (Accessibility error \(error.rawValue)) left it at \(rowFrame(window).map { "\($0)" } ?? "unread")")
        return false
    }

    func refresh() { refreshing() }

    func remember(_ image: CGImage) { remembering(image) }

    func ready() -> String? {
        guard let state = kosmosState() else { return "Kosmos did not answer kosmos state" }
        if state.workspaces.first(where: { $0.name == workspace })?.shown != false { return "workspace \(workspace) is shown" }
        guard inSpace(window, holding) else { return "the window is out of Kosmos's holding Space" }
        guard let frame = rowFrame(window), abs(frame.minX - rest.minX) < 1, abs(frame.minY - rest.minY) < 1,
              abs(frame.width - rest.width) < 1, abs(frame.height - rest.height) < 1 else {
            return "the window moved from \(rest) to \(rowFrame(window).map { "\($0)" } ?? "an unread frame")"
        }
        return nil
    }

    /// A switch that showed the workspace during the peek revealed the window as Kosmos has it,
    /// and the conceal after it took it back, so it leaves the holding Space again.
    func concealedAgain() -> String? {
        guard let state = kosmosState() else { return "Kosmos did not answer kosmos state" }
        guard state.workspaces.first(where: { $0.name == workspace })?.shown == true else { return nil }
        var ids = [window]
        kosmos_remove_windows(holding, &ids, 1)
        return "workspace \(workspace) was shown during the peek, so the window stays revealed, as Kosmos has it"
    }
}

/// Opens the app's window in the background, waits for Kosmos to manage it, sends it to
/// `workspace` and waits for Kosmos to conceal it there. Nil, having said why, when a step
/// fails; the cleanup then undoes what was done.
@MainActor func appTarget(_ app: PeekApp, on workspace: String, cleanup: PeekCleanup) -> AppTarget? {
    func fail(_ why: String) -> AppTarget? {
        print("\(app.name): \(why)")
        return nil
    }
    let files = FileManager.default
    let directory = files.temporaryDirectory.appending(path: "kosmos-probe-peek-\(getpid())-\(app.name.lowercased().filter(\.isLetter))")
    try? files.createDirectory(at: directory, withIntermediateDirectories: true)
    cleanup.add { try? FileManager.default.removeItem(at: directory) }
    let front = kosmos_front_pid()
    // Wall clock ms at uptime 0, for the page's count.
    let wall = Date().timeIntervalSince1970 * 1000 - uptime()
    let token = Locked("peek 0000")

    let opened: (NSRunningApplication?, String?), launched: Bool, before: Set<UInt32>, matches: (String) -> Bool
    let judge: @Sendable (CGImage, Double) -> Verdict
    var refresh: (UInt32, AXUIElement) -> Void = { _, _ in }
    var remember: @Sendable (CGImage) -> Void = { _ in }
    /// Reads the token in a capture, within the share of the window `crop` gives.
    func reading(_ crop: Locked<CGRect>?) -> @Sendable (CGImage, Double) -> Verdict {
        { image, _ in
            let band = crop?.value ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let pixels = CGRect(x: band.minX * CGFloat(image.width), y: band.minY * CGFloat(image.height),
                                width: band.width * CGFloat(image.width), height: band.height * CGFloat(image.height))
            let text = recognizedText(image.cropping(to: pixels.integral) ?? image)
            let current = squeezed(text).contains(squeezed(token.value))
            return Verdict(current: current, text: "text '\(text.prefix(48))'\(current ? ", current" : ""), \(Pixels(image).coverage)")
        }
    }
    switch app {
    case .chrome:
        guard let chrome = chromeForTesting() else { return fail("no Chrome for Testing under ~/Library/Caches/ms-playwright") }
        let t0 = Int((Date().timeIntervalSince1970 * 1000).rounded())
        let page = directory.appending(path: "peek.html")
        guard (try? countPage(t0: t0).write(to: page, atomically: true, encoding: .utf8)) != nil else { return fail("the page was not written") }
        opened = openInBackground(chrome, arguments: ["--user-data-dir=\(directory.appending(path: "profile").path)", "--no-first-run", "--use-mock-keychain",
                                                      // Chromium stops drawing an occluded window without these (docs/hiding.md).
                                                      "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
                                                      "--disable-background-timer-throttling",
                                                      "--no-default-browser-check", "--new-window", page.absoluteString],
                                  newInstance: true)
        (launched, before, matches) = (true, [], { _ in true })
        judge = { image, at in
            let pixels = Pixels(image), shot = pixels.badgeCount
            guard case .count(let shown, _) = shot else { return Verdict(current: nil, text: "\(shot), \(pixels.coverage)") }
            let lag = (Int((at + wall - Double(t0)) / peekTick) & 0xffff) - shown
            return Verdict(current: lag <= 1, text: "\(shot) lag \(lag), \(pixels.coverage)")
        }
    case .finder:
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return fail("Finder is not running")
        }
        let file = Locked(directory.appending(path: "peek 0000"))
        guard files.createFile(atPath: file.value.path, contents: Data()) else { return fail("the file was not made") }
        before = Set(axWindows(finder.processIdentifier).map(\.id))
        opened = openInBackground(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), urls: [directory])
        let title = directory.lastPathComponent
        (launched, matches) = (false, { $0 == title })
        judge = reading(nil)
        refresh = { _, _ in
            let next = nextToken(after: token.value)
            let renamed = directory.appending(path: next)
            do {
                try FileManager.default.moveItem(at: file.value, to: renamed)
                file.value = renamed
                token.value = next
            } catch {
                print("  Finder: the rename to '\(next)' failed: \(error.localizedDescription)")
            }
        }
    case .textEdit:
        let file = directory.appending(path: "kosmos-probe-peek.rtf")
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica-Bold;}}\f0\fs144 peek 0000}"#
        guard (try? rtf.write(to: file, atomically: true, encoding: .utf8)) != nil else { return fail("the document was not written") }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
        before = running.map { Set(axWindows($0.processIdentifier).map(\.id)) } ?? []
        opened = openInBackground(URL(fileURLWithPath: "/System/Applications/TextEdit.app"), urls: [file],
                                  arguments: ["-ApplePersistenceIgnoreState", "YES"])
        (launched, matches) = (running == nil, { $0.hasPrefix("kosmos-probe-peek") })
        // The text's top band, as a share of the window at the frame it has when its text is set;
        // Kosmos gives it another frame on the hidden workspace.
        let band = Locked(CGRect(x: 0, y: 0, width: 1, height: 1))
        judge = reading(band)
        var area: AXUIElement?
        refresh = { _, window in
            if area == nil { area = axFind(window, role: kAXTextAreaRole) }
            guard let area else { return print("  TextEdit: no text area") }
            if let text = axFrame(area), let frame = axFrame(window), frame.width > 0, frame.height > 0 {
                let top = text.intersection(frame)
                band.value = CGRect(x: (top.minX - frame.minX) / frame.width, y: (top.minY - frame.minY) / frame.height,
                                    width: top.width / frame.width, height: min(top.height, 200) / frame.height)
            }
            let next = nextToken(after: token.value)
            let error = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, next as CFString)
            if error == .success { token.value = next } else { print("  TextEdit: the text was not set: Accessibility error \(error.rawValue)") }
        }
    case .electron(let name):
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        guard let bundle = Bundle(url: url)?.bundleIdentifier else { return fail("no app at \(url.path)") }
        guard files.fileExists(atPath: url.appending(path: "Contents/Frameworks/Electron Framework.framework").path) else {
            return fail("not an Electron app")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
            return fail("already running; the probe peeks only an app it launches, so none of your windows moves")
        }
        opened = openInBackground(url)
        (launched, before, matches) = (true, [], { _ in true })
        let last = Locked<[Double]?>(nil)
        judge = { image, _ in
            let pixels = Pixels(image), marks = pixels.fingerprint, black = pixels.blackShare > 0.9
            // The cell that changed most, so a change as small as a caret counts.
            let distance = last.value.map { zip(marks, $0).map { abs($0 - $1) }.max() ?? 0 }
            let fresh = !black && (distance ?? 255) > 2
            return Verdict(current: fresh, text: "\(black ? "black" : "drawn"), "
                           + (distance.map { String(format: "%.1f levels from the last capture at most", $0) } ?? "no capture before")
                           + ", \(pixels.coverage)")
        }
        remember = { image in last.value = Pixels(image).fingerprint }
    }
    guard let running = opened.0 else { return fail("did not open: \(opened.1 ?? "no app")") }
    let pid = running.processIdentifier
    if launched {
        let box = Unchecked(value: running)
        cleanup.add { quit(box.value) }
    }

    // The new window, the largest that matches; an Electron app can show a smaller one first.
    var deadline = uptime() + 20000
    func newest() -> AXWindow? {
        axWindows(pid).filter { !before.contains($0.id) && matches($0.title) }.max { $0.area < $1.area }
    }
    var found = newest()
    while found == nil && uptime() < deadline {
        pumpEvents(0.2)
        found = newest()
    }
    if case .electron = app, found != nil {
        pumpEvents(2)
        found = newest() ?? found
    }
    guard let found else { return fail("no new window within 20 s; Finder may have opened a tab in a window of yours") }
    let window = found.id, element = found.element
    if !launched {
        let box = Unchecked(value: element)
        cleanup.add {
            if let button = axCopy(box.value, kAXCloseButtonAttribute) { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
        }
    }
    if kosmos_front_pid() != front { print("\(app.name): warning: the open changed the front app from pid \(front) to \(kosmos_front_pid())") }

    deadline = uptime() + 10000
    var placed: String?
    while placed == nil && uptime() < deadline {
        placed = kosmosState()?.workspaces.first { $0.windows.contains { $0.id == window } }?.name
        if placed == nil { pumpEvents(0.1) }
    }
    guard let placed else { return fail("Kosmos did not manage window \(window) within 10 s") }
    refresh(window, element)
    let at = uptime()
    let (image, error, _) = captureWindow(window, size: nil)
    if let image { remember(image) }
    print("\(app.name): window \(window) of pid \(pid), titled '\(found.title)', one of \(axWindows(pid).count) standard windows "
          + "of its app on shown Spaces, managed on workspace \(placed); "
          + "a capture there: \(image.map { judge($0, at) } ?? .failed(error ?? "no image"))")
    if placed != workspace {
        let reply = try? IPCClient.send(["move-node-to-workspace", "--window-id", "\(window)", workspace], socketPath: kosmosSocketPath())
        guard reply?.exitCode == 0 else { return fail("kosmos move-node-to-workspace failed: \(reply?.stderr ?? "no answer")") }
    }
    deadline = uptime() + 3000
    var holding: UInt64?
    while holding == nil && uptime() < deadline {
        holding = RecordFile.peek(KosmosFiles.record)?.spaces.first { inSpace(window, $0) }
        if holding == nil { pumpEvents(0.05) }
    }
    guard let holding else { return fail("Kosmos did not conceal it within 3 s") }
    // Kosmos writes the window's tile on the workspace once the conceal is done.
    deadline = uptime() + 5000
    var frame = rowFrame(window), still = uptime()
    while uptime() - still < 500 && uptime() < deadline {
        pumpEvents(0.05)
        let now = rowFrame(window)
        if now != frame { (frame, still) = (now, uptime()) }
    }
    guard let frame else { return fail("its frame did not read") }
    let spaces = SkyLight.spaces(of: window) ?? []
    print(String(format: "%@: concealed by Kosmos on workspace %@ in its holding Space %llu, %.0f by %.0f at (%.0f, %.0f), its ordinary Spaces %@",
                 app.name, workspace, holding, frame.width, frame.height, frame.minX, frame.minY, spaces.isEmpty ? "none, stripped" : "\(spaces)"))
    return AppTarget(name: app.name, window: window, pid: pid, element: element, holding: holding, rest: frame, workspace: workspace,
                     judge: judge, refresh: { [refresh] in refresh(window, element) }, remember: remember)
}
