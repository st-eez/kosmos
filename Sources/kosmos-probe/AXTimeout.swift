// Accessibility reads of an app that is launching, answering and hung (docs/overview.md).
//
//   kosmos-probe ax-timeout         What Accessibility returns, and how long it takes, for a
//                                   child app that is launching, answering and hung. The
//                                   child is an accessory app with no window, which a running
//                                   Kosmos ignores. Needs Accessibility for the terminal.
import AppKit

/// An accessory app with no window. Each number on stdin hangs its main thread for that many
/// seconds, then it prints "awake". Prints "ready" once its run loop runs.
@MainActor func axChild() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Thread.detachNewThread {
        while let line = readLine() {
            guard let seconds = Double(line) else { continue }
            DispatchQueue.main.async {
                Thread.sleep(forTimeInterval: seconds)
                print("awake")
            }
        }
        exit(0)
    }
    DispatchQueue.main.async { print("ready") }
    app.run()
    exit(0)
}

func axTimeout() {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["ax-child"]
    let input = Pipe(), output = Pipe()
    child.standardInput = input
    child.standardOutput = output
    func line() -> String {
        var bytes = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
    func hang(_ seconds: Double) { input.fileHandleForWriting.write(Data("\(seconds)\n".utf8)) }
    func read(_ element: AXUIElement) -> (AXError, Double) {
        var value: CFTypeRef?
        let start = ContinuousClock.now
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return (result, elapsed(start))
    }
    func show(_ result: (AXError, Double)) -> String { String(format: "error %d in %.1f ms", result.0.rawValue, result.1) }
    let systemWide = AXUIElementCreateSystemWide()

    // Launching: read from the moment of the spawn until the child answers.
    let spawned = ContinuousClock.now
    try! child.run()
    defer { child.terminate() }
    let pid = child.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var failures: [Int32: Int] = [:]
    var slowest = 0.0
    var answered: Double?
    while elapsed(spawned) < 5000 {
        let result = read(app)
        if result.0 == .success { answered = elapsed(spawned); break }
        failures[result.0.rawValue, default: 0] += 1
        slowest = max(slowest, result.1)
        usleep(5000)
    }
    print("launching: failures by error \(failures.sorted { $0.key < $1.key }), slowest failure \(String(format: "%.1f", slowest)) ms, first answer \(answered.map { String(format: "%.0f ms", $0) } ?? "none") after spawn")
    _ = line()   // ready

    var times = (0..<20).map { _ in read(app).1 }
    print(String(format: "answering: read median %.3f ms, max %.3f ms", percentile(times, 0.5), percentile(times, 1)))

    // Hung: one read with no timeout set anywhere, then one per element timeout.
    hang(4)
    usleep(100_000)
    print("hung, no timeout set: \(show(read(AXUIElementCreateApplication(pid))))")
    for timeout: Float in [0.05, 0.25, 1.0] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        print("hung, element timeout \(timeout) s: \(show(read(element)))")
    }
    var observer: AXObserver?
    AXObserverCreate(pid, { _, _, _, _ in }, &observer)
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.25)
    var start = ContinuousClock.now
    let added = AXObserverAddNotification(observer!, element, kAXFocusedWindowChangedNotification as CFString, nil)
    print(String(format: "hung, add observer notification, element timeout 0.25 s: error %d in %.1f ms", added.rawValue, elapsed(start)))
    _ = line()   // awake

    // A fresh element takes the system wide timeout.
    hang(3)
    usleep(100_000)
    AXUIElementSetMessagingTimeout(systemWide, 0.25)
    print("hung, fresh element, system wide timeout 0.25 s: \(show(read(AXUIElementCreateApplication(pid))))")
    AXUIElementSetMessagingTimeout(systemWide, 0)
    print("hung, fresh element, system wide timeout reset with 0: \(show(read(AXUIElementCreateApplication(pid))))")
    _ = line()

    // Requests that timed out still wait in the app's queue: time the first answer after a
    // hang during which 10 probes gave up.
    hang(1.5)
    usleep(100_000)
    let prober = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(prober, 0.05)
    for _ in 0..<10 { _ = read(prober) }
    _ = line()
    start = ContinuousClock.now
    let after = read(app)
    print("after a hang with 10 abandoned requests: \(show(after)); \(String(format: "%.1f", elapsed(start))) ms")
    times = (0..<20).map { _ in read(app).1 }
    print(String(format: "answering again: read median %.3f ms", percentile(times, 0.5)))
}
