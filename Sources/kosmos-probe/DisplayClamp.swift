// What a frame write lands as when it moves a window between the built-in display and the
// wider display above it, by the order of its Accessibility calls (docs/geometry.md).
//
//   kosmos-probe display-clamp [trials] [later]
//                                   A titled window of a child app Kosmos does not manage
//                                   starts at the built-in display's tile, 10 pt gaps and
//                                   5 pt at the top, and is written the tile of the display
//                                   above, 35 pt at the top and 10 pt elsewhere, then back.
//                                   Each order of size and position calls runs `trials`
//                                   times each way, 10 by default, with the target as tiled
//                                   and 1 pt shorter, as AeroSpace writes its tiles; then the
//                                   orders that pass through a height 40 pt shorter, and the
//                                   target 30 pt shorter, its bottom out of AppKit's 25 pt
//                                   zone at the edge the displays share. later writes the
//                                   size again 0 to 100 ms after the move up instead, the
//                                   frame in one AXFrame call, and the size alone to a
//                                   window its app placed on the display above. Prints
//                                   the sizes read back at once, 50 ms and 300 ms after the
//                                   last call, how many trials took the target, and the
//                                   calls' time. The window shows on both displays. Needs
//                                   Accessibility for the terminal.
import AppKit
import CKosmos

/// Prints its window id, then on each `place x y w h` line, in Accessibility's coordinates,
/// sets its frame and prints `placed`. Exits when stdin closes.
@MainActor func clampWindow() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 300),
                          styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "kosmos-probe display-clamp"
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    print(window.windowNumber)
    Thread.detachNewThread {
        while let line = readLine() {
            let numbers = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard numbers.count == 4 else { continue }
            DispatchQueue.main.async {
                let top = NSScreen.screens[0].frame.maxY
                window.setFrame(NSRect(x: numbers[0], y: top - numbers[1] - numbers[3], width: numbers[2], height: numbers[3]),
                                display: true)
                print("placed")
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

private enum Order: Equatable {
    case sizePositionSize, positionSize, positionSizePosition, sizePositionSizeThenSize
    /// Kosmos's retry of a height AppKit ignored near a display edge, made whatever the read.
    case sizePositionSizeThenShorter, sizePositionShorterSize, shorterPositionSize
    /// The size written again this many milliseconds after size-position-size.
    case sizeAfter(Double)
    /// After size-position-size, the size written again every `pause` milliseconds, each
    /// time a read shows it clamped, for up to 100 ms.
    case sizeUntilTaken(pause: Double)
    /// The whole frame in one call, as `AXFrame`.
    case frame
    /// Only the size, to a window its app placed on the target's display.
    case size

    var name: String {
        switch self {
        case .sizePositionSize: "size-position-size"
        case .positionSize: "position-size"
        case .positionSizePosition: "position-size-position"
        case .sizePositionSizeThenSize: "size-position-size, read, size"
        case .sizePositionSizeThenShorter: "size-position-size, read, size 40 pt shorter, size"
        case .sizePositionShorterSize: "size-position, size 40 pt shorter, size"
        case .shorterPositionSize: "size 40 pt shorter-position-size"
        case .sizeAfter(let wait): "size-position-size, size \(Int(wait)) ms later"
        case .sizeUntilTaken(let pause): "size-position-size, then read and size every \(Int(pause)) ms until it takes"
        case .frame: "AXFrame"
        case .size: "size, placed on the display by the app"
        }
    }

    static let asked: [Order] = [.sizePositionSize, .positionSize, .positionSizePosition, .sizePositionSizeThenSize]
    static let shorter: [Order] = [.sizePositionSizeThenShorter, .sizePositionShorterSize, .shorterPositionSize]
    static let later: [Order] = [0, 5, 10, 20, 50, 100].map { .sizeAfter($0) } + [.sizeUntilTaken(pause: 0), .sizeUntilTaken(pause: 2)]
        + [.frame, .size]
}

@MainActor func displayClamp(trials: Int, later: Bool) -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let builtIn = builtInScreen()
    let lower = CGDisplayBounds(builtIn.displayID)
    guard let upperScreen = NSScreen.screens.first(where: {
        let bounds = CGDisplayBounds($0.displayID)
        return bounds.maxY == lower.minY && bounds.minX < lower.maxX && lower.minX < bounds.maxX
    }) else { print("no display sits directly above the built-in display"); exit(1) }
    // Visible frames in Accessibility's coordinates, with Steve's gaps.
    func area(_ screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame, top = NSScreen.screens[0].frame.maxY
        return CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height)
    }
    let lowerArea = area(builtIn), upperArea = area(upperScreen)
    let lowerTile = CGRect(x: lowerArea.minX + 10, y: lowerArea.minY + 5, width: lowerArea.width - 20, height: lowerArea.height - 15)
    let upperTile = CGRect(x: upperArea.minX + 10, y: upperArea.minY + 35, width: upperArea.width - 20, height: upperArea.height - 45)
    print("built-in \(describe(CGDisplayBounds(builtIn.displayID))), tile \(describe(lowerTile))")
    print("above \(upperScreen.localizedName) \(describe(CGDisplayBounds(upperScreen.displayID))), tile \(describe(upperTile))")

    // A crash closes the child's stdin too, which closes its window.
    let child = Child(["clamp-window"])
    guard let window = child.readWindows().first else { print("no window"); exit(1) }
    let app = AXUIElementCreateApplication(child.pid)
    AXUIElementSetMessagingTimeout(app, 1)
    var element: AXUIElement?
    for _ in 0..<100 where element == nil {
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success {
            element = (windows as? [AXUIElement] ?? []).first { candidate in
                var id: UInt32 = 0
                return _AXUIElementGetWindow(candidate, &id) == .success && id == window
            }
        }
        if element == nil { usleep(20_000) }
    }
    guard let element else { print("window \(window) has no Accessibility element"); child.quit(); exit(1) }

    func place(_ frame: CGRect) {
        child.send("place \(frame.minX) \(frame.minY) \(frame.width) \(frame.height)")
        _ = child.line()
        usleep(150_000)   // for the display change to reach the app
    }
    place(lowerTile)
    guard let managed = managedWindows(), !managed.contains(window) else {
        print("Kosmos manages window \(window), or kosmos list-windows did not answer; stopping")
        child.quit()
        exit(1)
    }
    print("window \(window), pid \(child.pid), not managed by Kosmos")

    func set(_ attribute: String, _ value: CGPoint) {
        var value = value
        _ = AXUIElementSetAttributeValue(element, attribute as CFString, AXValueCreate(.cgPoint, &value)!)
    }
    func set(_ attribute: String, _ value: CGSize) {
        var value = value
        _ = AXUIElementSetAttributeValue(element, attribute as CFString, AXValueCreate(.cgSize, &value)!)
    }
    func read() -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero, p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
        if let p { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
        if let s { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    // The orders asked for each way, as tiled and 1 pt shorter; then the orders that go
    // through a shorter height each way, and the first orders with the target's bottom out of
    // AppKit's 25 pt zone at a display edge.
    // With `later`: the size written again some time after the move, the frame in one call,
    // and the size alone to a window its app placed on the display above at the clamped width.
    let up = (name: "up", from: lowerTile, to: upperTile), down = (name: "down", from: upperTile, to: lowerTile)
    var runs: [(order: Order, way: (name: String, from: CGRect, to: CGRect), trim: CGFloat)] = []
    if later {
        for order in Order.later {
            let from = order == .size ? CGRect(x: upperTile.minX, y: upperTile.minY, width: lower.maxX - upperTile.minX,
                                               height: upperTile.height) : lowerTile
            runs.append((order, (up.name, from, upperTile), 0))
        }
    } else {
        for trim: CGFloat in [0, 1] { for way in [up, down] { for order in Order.asked { runs.append((order, way, trim)) } } }
        for way in [up, down] { for order in Order.shorter { runs.append((order, way, 0)) } }
        for order in Order.asked { runs.append((order, up, 30)) }
    }

    print("order | direction | target | read between | at once | 50 ms | 300 ms | took at once, 50, 300 ms | calls ms median, max")
    for (order, way, trim) in runs {
        let target = CGRect(x: way.to.minX, y: way.to.minY, width: way.to.width, height: way.to.height - trim)
        let shorter = CGSize(width: target.width, height: target.height - 40)
        var between: [CGRect] = [], reads: [[CGRect]] = [[], [], []], times: [Double] = [], errors: Set<Int32> = []
        var retries: [Int] = []
        func took(_ frame: CGRect) -> Bool {
            frame.origin == target.origin && abs(frame.width - target.width) <= 2 && abs(frame.height - target.height) <= 2
        }
        for _ in 0..<trials {
            place(way.from)
            let start = ContinuousClock.now
            switch order {
            case .sizePositionSize, .sizePositionSizeThenSize, .sizePositionSizeThenShorter:
                set(kAXSizeAttribute, target.size)
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
            case .positionSize:
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
            case .positionSizePosition:
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
                set(kAXPositionAttribute, target.origin)
            case .sizePositionShorterSize:
                set(kAXSizeAttribute, target.size)
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, shorter)
                set(kAXSizeAttribute, target.size)
            case .shorterPositionSize:
                set(kAXSizeAttribute, shorter)
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
            case .sizeAfter(let wait):
                set(kAXSizeAttribute, target.size)
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
                between.append(read())
                usleep(useconds_t(wait * 1000))
                set(kAXSizeAttribute, target.size)
            case .sizeUntilTaken(let pause):
                set(kAXSizeAttribute, target.size)
                set(kAXPositionAttribute, target.origin)
                set(kAXSizeAttribute, target.size)
                var sets = 0
                while elapsed(start) < 100, !took(read()) {
                    if pause > 0 { usleep(useconds_t(pause * 1000)) }
                    set(kAXSizeAttribute, target.size)
                    sets += 1
                }
                retries.append(sets)
            case .frame:
                var value = target
                errors.insert(AXUIElementSetAttributeValue(element, "AXFrame" as CFString, AXValueCreate(.cgRect, &value)!).rawValue)
            case .size:
                set(kAXSizeAttribute, target.size)
            }
            if order == .sizePositionSizeThenSize || order == .sizePositionSizeThenShorter {
                between.append(read())
                if order == .sizePositionSizeThenShorter { set(kAXSizeAttribute, shorter) }
                set(kAXSizeAttribute, target.size)
            }
            times.append(elapsed(start))
            let written = ContinuousClock.now
            reads[0].append(read())
            for (index, delay) in [(1, 50.0), (2, 300.0)] {
                let wait = delay - elapsed(written)
                if wait > 0 { usleep(useconds_t(wait * 1000)) }
                reads[index].append(read())
            }
        }
        let columns = [between.isEmpty ? "-" : tally(between, target)] + reads.map { tally($0, target) }
        let counts = reads.map { "\($0.filter(took).count)" }.joined(separator: ", ")
        print("""
            \(order.name) | \(way.name) | \(describe(target)) | \(columns.joined(separator: " | ")) | \
            \(counts) of \(trials) | \(String(format: "%.1f, %.1f", percentile(times, 0.5), percentile(times, 1)))\
            \(errors.isEmpty ? "" : " | AXError \(errors.sorted())")\
            \(retries.isEmpty ? "" : " | sizes written again: median \(retries.sorted()[retries.count / 2]), most \(retries.max()!)")
            """)
    }
    child.quit()
    exit(0)
}

private func describe(_ frame: CGRect) -> String {
    "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)), \(Int(frame.minY))"
}

/// Each size read, with its count, and the origin when it is not the target's.
private func tally(_ frames: [CGRect], _ target: CGRect) -> String {
    var counts: [String: Int] = [:], order: [String] = []
    for frame in frames {
        var key = "\(Int(frame.width))x\(Int(frame.height))"
        if frame.origin != target.origin { key += " at \(Int(frame.minX)), \(Int(frame.minY))" }
        if counts[key] == nil { order.append(key) }
        counts[key, default: 0] += 1
    }
    return order.map { "\($0) (\(counts[$0]!))" }.joined(separator: ", ")
}

/// The windows `kosmos list-windows` lists, nil when it did not answer.
private func managedWindows() -> Set<UInt32>? {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["kosmos", "list-windows"]
    process.standardOutput = output
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return Set(text.split(separator: "\n").compactMap { $0.split(separator: " ").first.flatMap { UInt32($0) } })
}
