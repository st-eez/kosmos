// kosmos-probe space-anim: can Kosmos animate another app's window with SIP on by putting it
// alone in a shown Space and setting that Space's transform each display frame, so the
// compositor moves it and the app does no work per frame? No bridged operation transforms or
// fades one window, and a transform set on another app's window returns success and does
// nothing on macOS 27, but SLSBridgedSpaceSetTransformOperation and SetAlpha act on a Space.
// The holding Space moves its windows off every display that way (DESIGN.md, section 5.3),
// and float-layer showed that a window added to a Space shown in place renders in it.
//
// Step 1: a stub app with the prohibited activation policy opens one opaque 200 by 150 point
// window at the bottom left of the built-in display. It joins a new Space shown one level
// above the desktop Space's and keeps its ordinary Space. The Space's transform goes to a
// translation of 300 points in x, then 100 in y, a scale of 0.5 alone, then a scale of 0.5
// about the window's top left corner, alone and with the translation in x. After each the
// probe reads the transform back, scans the displays for where WindowServer's hit test names
// the window, reads the hit test at points inside and just outside where the window should
// be, and reads the window's bounds from the window list, SkyLight and Accessibility. The
// translations and the plain scale give the convention: which way the transform maps, which
// way y points, and the point it scales about.
//
// The stub can never be the front process and Kosmos leaves it alone, so the probe takes no
// focus. Its window shows for a few seconds. However the probe exits, Ctrl-C included, it
// kills the stub, which takes the window away, then destroys its Spaces; only a SIGKILL
// leaves the Spaces, empty. Needs Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos
import KosmosSkyLight

@MainActor func spaceAnim() -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    let app = NSApplication.shared   // bridged operations need an AppKit client
    app.setActivationPolicy(.prohibited)
    guard builtInScreen() != nil else { print("no built-in display"); exit(1) }
    installCleanup()
    let probe = SpaceAnim()
    if let found = probe.step1() {
        print("step 1: yes. \(found.convention.description)")
    } else {
        print("step 1: no")
    }
    probe.finish()
}

/// How a Space's transform places a window, found in step 1. The transform acts in a frame
/// whose y points up when `flipped`, with its origin at `origin`: in CoreGraphics' global
/// coordinates, or relative to the window's top left corner when `followsWindow`. It maps a
/// window's point to where it shows, or the reverse when `inverse`.
struct SpaceTransformConvention {
    var inverse: Bool
    var flipped: Bool
    var followsWindow: Bool
    var origin: CGPoint

    /// The Space transform that shows each point p of the window at `frame` at `shown` applied
    /// to p, both in CoreGraphics' global coordinates.
    func transform(showing shown: CGAffineTransform, for frame: CGRect) -> CGAffineTransform {
        let o = followsWindow ? CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y) : origin
        let toFrame = CGAffineTransform(a: 1, b: 0, c: 0, d: flipped ? -1 : 1, tx: -o.x, ty: flipped ? o.y : -o.y)
        let inFrame = toFrame.inverted().concatenating(shown).concatenating(toFrame)
        return inverse ? inFrame.inverted() : inFrame
    }

    var description: String {
        "The transform maps \(inverse ? "where the window shows to the window" : "the window to where it shows"), "
            + "with y \(flipped ? "up" : "down") and its origin "
            + (followsWindow ? (origin == .zero ? "at the window's top left corner" : "\(format(origin)) from the window's top left corner")
                             : "at \(format(origin)) in CoreGraphics' global coordinates")
    }
}

@MainActor final class SpaceAnim {
    let stub: KeyStub
    let window: UInt32
    let element: AXUIElement?
    /// The window's frame before any transform, from SkyLight, in CoreGraphics' coordinates.
    let frame: CGRect
    /// The height of the display at the origin, to turn CoreGraphics' points into AppKit's.
    let mainHeight: CGFloat
    /// The displays' bounds in CoreGraphics' coordinates, the built-in display first.
    let displays: [CGRect]
    let level: Int32
    /// Every Space the probe created, read back at the end.
    var created: [UInt64] = []

    init() {
        stub = KeyStub("S", arguments: ["float-stub", "prohibited", "S", "400,200,200,150"])
        track(stub: stub.process)
        window = stub.windows[0]
        mainHeight = NSScreen.screens.first?.frame.height ?? 0
        displays = NSScreen.screens.compactMap { screen -> (builtIn: Bool, bounds: CGRect)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (CGDisplayIsBuiltin(id) != 0, CGDisplayBounds(id))
        }.sorted { $0.builtIn && !$1.builtIn }.map(\.bounds)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))   // let the window reach the screen
        frame = SkyLight.rows([window]).first?.frame ?? .null
        element = windowElement(stub.pid, window)
        let desktop = Displays.current().currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) ?? 0
        level = SLSSpaceGetAbsoluteLevel(SkyLight.connection, desktop) + 1
        print("stub window \(window) at \(format(frame)); the desktop Space \(desktop) is at level \(level - 1)")
    }

    /// Step 1. Returns the convention and the Space, with the window in it at the identity
    /// transform, if translation and scale both move where the window is hit as predicted.
    func step1() -> (convention: SpaceTransformConvention, space: UInt64)? {
        guard let space = createSpace() else { return nil }
        add(window, to: space)
        print("Space \(space) at level \(level) reads level \(SLSSpaceGetAbsoluteLevel(SkyLight.connection, space)); "
              + "window in it \(inSpace(window, space)), ordinary Spaces \(kosmos_window_spaces(window) as? [UInt64] ?? [])")
        guard observe(space, "identity", .identity, expect: frame).located?.equalTo(frame, within: 1) == true else {
            print("with the identity transform the hit test does not find the window at its frame")
            return nil
        }

        // Until the translations show otherwise, the expected rectangles assume the transform
        // maps the window to where it shows in CoreGraphics' global coordinates.
        let x = observe(space, "translation of 300 in x", CGAffineTransform(translationX: 300, y: 0),
                        expect: frame.offsetBy(dx: 300, dy: 0))
        guard let moved = x.located, abs(moved.width - frame.width) < 1, abs(abs(moved.minX - frame.minX) - 300) < 1,
              abs(moved.minY - frame.minY) < 1 else {
            print("the hit test did not move by 300 points in x")
            return nil
        }
        let inverse = moved.minX < frame.minX
        let y = observe(space, "translation of 100 in y", CGAffineTransform(translationX: 0, y: 100),
                        expect: frame.offsetBy(dx: 0, dy: 100))
        guard let lifted = y.located, abs(abs(lifted.minY - frame.minY) - 100) < 1, abs(lifted.minX - frame.minX) < 1 else {
            print("the hit test did not move by 100 points in y")
            return nil
        }
        let down = lifted.minY > frame.minY

        // A shown scale of 0.5 needs a transform of 2 when it maps where the window shows to
        // the window. A shown scale of 0.5 about O puts the corner p at O + (p - O) / 2, so
        // O = 2 p' - p. The window then moves by Accessibility, and the scale's O moves with it
        // or stays.
        let scale = inverse ? CGAffineTransform(scaleX: 2, y: 2) : CGAffineTransform(scaleX: 0.5, y: 0.5)
        var fixed: [CGPoint] = []
        for shift in [CGVector.zero, CGVector(dx: 200, dy: -100)] {
            let at = frame.offsetBy(dx: shift.dx, dy: shift.dy)
            if let element, shift != .zero { print("  window moved by Accessibility to \(format(at)): \(setFrame(element, at).map(\.rawValue))") }
            let scaled = observe(space, "scale of \(scale.a)", scale, expect: at.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)))
            guard let small = scaled.located, abs(small.width - frame.width / 2) < 1, abs(small.height - frame.height / 2) < 1 else {
                print("the hit test did not follow the scale to half the window's size")
                return nil
            }
            fixed.append(CGPoint(x: 2 * small.minX - at.minX, y: 2 * small.minY - at.minY))
            print("  so the scale's fixed point is \(format(fixed.last!)), \(format(CGPoint(x: fixed.last!.x - at.minX, y: fixed.last!.y - at.minY))) from the window's top left")
        }
        if let element { _ = setFrame(element, frame) }
        let followsWindow = abs(fixed[1].x - fixed[0].x - 200) < 1 && abs(fixed[1].y - fixed[0].y + 100) < 1
        guard followsWindow || hypot(fixed[1].x - fixed[0].x, fixed[1].y - fixed[0].y) < 1 else {
            print("the scale's fixed point neither stayed nor moved with the window")
            return nil
        }
        // The edges are found to a quarter point, so the fixed point to half a point; windows
        // sit on whole points.
        let origin = followsWindow ? CGPoint(x: (fixed[0].x - frame.minX).rounded(), y: (fixed[0].y - frame.minY).rounded())
                                   : CGPoint(x: fixed[0].x.rounded(), y: fixed[0].y.rounded())
        let convention = SpaceTransformConvention(inverse: inverse, flipped: inverse == down, followsWindow: followsWindow, origin: origin)
        print("  so: \(convention.description)")

        let aboutCorner = CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: frame.minX / 2, ty: frame.minY / 2)
        let halved = observe(space, "scale of 0.5 about the window's top left", convention.transform(showing: aboutCorner, for: frame),
                             expect: frame.applying(aboutCorner))
        let both = aboutCorner.concatenating(CGAffineTransform(translationX: 300, y: 0))
        let combined = observe(space, "the same scale, then a translation of 300 in x", convention.transform(showing: both, for: frame),
                               expect: frame.applying(both))
        let back = observe(space, "identity again", .identity, expect: frame)
        guard halved.predicted, combined.predicted, back.predicted else {
            print("the hit test did not land where the convention predicts")
            return nil
        }
        return (convention, space)
    }

    struct Observation {
        /// Where the hit test names the window, or nil if no display shows it.
        let located: CGRect?
        /// Whether the hit test named the window at every point inside the expected rectangle
        /// and at none just outside it.
        let predicted: Bool
    }

    /// Sets the Space's transform, waits for it with a barrier and 50 ms, and prints the
    /// transform read back, where the hit test names the window, the hit test inside and just
    /// outside `expect` if given, and the window's bounds as the window list, SkyLight and
    /// Accessibility read them.
    @discardableResult
    func observe(_ space: UInt64, _ step: String, _ transform: CGAffineTransform, expect: CGRect?) -> Observation {
        let sent = kosmos_space_set_transform(space, transform)
        _ = kosmos_barrier(space)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        var actual = CGAffineTransform.identity
        let read = kosmos_space_get_transform(space, &actual)
        let start = ContinuousClock.now
        let (located, tests) = locate()
        print("\(step): set \(format(transform)) (sent \(sent)), reads \(read ? format(actual) : "nothing")")
        print("  hit region \(located.map(format) ?? "on no display") (\(tests) hit tests in "
              + String(format: "%.0f ms)", elapsed(start)))
        var predicted = false
        if let expect {
            // Points 3 points either side of each edge's middle, since the corners are round.
            let inside = [CGPoint(x: expect.midX, y: expect.midY),
                          CGPoint(x: expect.minX + 3, y: expect.midY), CGPoint(x: expect.maxX - 3, y: expect.midY),
                          CGPoint(x: expect.midX, y: expect.minY + 3), CGPoint(x: expect.midX, y: expect.maxY - 3)]
            let outside = [CGPoint(x: expect.minX - 3, y: expect.midY), CGPoint(x: expect.maxX + 3, y: expect.midY),
                           CGPoint(x: expect.midX, y: expect.minY - 3), CGPoint(x: expect.midX, y: expect.maxY + 3)]
            let insideHits = inside.map(hit), outsideHits = outside.map(hit)
            predicted = insideHits.allSatisfy { $0 == window } && !outsideHits.contains(window)
            print("  expected \(format(expect)): inside (center, left, right, top, bottom) \(insideHits.map(label).joined(separator: ", ")); "
                  + "just outside (left, right, top, bottom) \(outsideHits.map(label).joined(separator: ", "))")
        }
        print("  bounds: \(bounds())")
        return Observation(located: located, predicted: predicted)
    }

    /// The window's bounds as the window list, SkyLight and Accessibility read them.
    func bounds() -> String {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
        let list = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        return "window list \(list.map(format) ?? "none"), SkyLight \(SkyLight.rows([window]).first.map { format($0.frame) } ?? "none"), "
            + "AX \(element.map { format(axFrame($0)) } ?? "no element")"
    }

    /// Where WindowServer's hit test names the window: the bounding rectangle of the hits on
    /// a 20 point grid over the built-in display, else over the first other display that has
    /// any, with each edge then found to a quarter point through the hit nearest its middle.
    /// Assumes the region is a rectangle. Returns it, or nil, and the number of hit tests.
    func locate() -> (CGRect?, Int) {
        let step: CGFloat = 20
        var tests = 0
        func hits(_ point: CGPoint) -> Bool {
            tests += 1
            return hit(point) == window
        }
        for bounds in displays {
            var found: [CGPoint] = []
            for y in stride(from: bounds.minY + step / 2, to: bounds.maxY, by: step) {
                for x in stride(from: bounds.minX + step / 2, to: bounds.maxX, by: step) where hits(CGPoint(x: x, y: y)) {
                    found.append(CGPoint(x: x, y: y))
                }
            }
            guard let minX = found.map(\.x).min(), let maxX = found.map(\.x).max(),
                  let minY = found.map(\.y).min(), let maxY = found.map(\.y).max() else { continue }
            let middle = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            let anchor = found.min { hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y) }!
            func edge(_ inside: CGFloat, _ outside: CGFloat, _ point: (CGFloat) -> CGPoint) -> CGFloat {
                var inside = inside, outside = outside
                while abs(outside - inside) > 0.25 {
                    let half = (inside + outside) / 2
                    if hits(point(half)) { inside = half } else { outside = half }
                }
                return (inside + outside) / 2
            }
            let left = edge(anchor.x, minX - step) { CGPoint(x: $0, y: anchor.y) }
            let right = edge(anchor.x, maxX + step) { CGPoint(x: $0, y: anchor.y) }
            let top = edge(anchor.y, minY - step) { CGPoint(x: anchor.x, y: $0) }
            let bottom = edge(anchor.y, maxY + step) { CGPoint(x: anchor.x, y: $0) }
            return (CGRect(x: left, y: top, width: right - left, height: bottom - top), tests)
        }
        return (nil, tests)
    }

    /// The window WindowServer's hit test names at a point in CoreGraphics' coordinates, or 0.
    func hit(_ point: CGPoint) -> UInt32 {
        UInt32(clamping: NSWindow.windowNumber(at: NSPoint(x: point.x, y: mainHeight - point.y), belowWindowWithWindowNumber: 0))
    }

    func label(_ hit: UInt32) -> String {
        if hit == window { return "stub" }
        if hit == 0 { return "none" }
        guard let row = SkyLight.rows([hit]).first else { return "\(hit)" }
        return "\(hit) (\(NSRunningApplication(processIdentifier: row.pid)?.localizedName ?? "pid \(row.pid)"))"
    }

    /// A new Space at the probe's level, in place and opaque, tracked for cleanup.
    func createSpace() -> UInt64? {
        let space = kosmos_float_space_create(level)
        guard space != 0 else { print("Space not created"); return nil }
        track(space: space)
        created.append(space)
        return space
    }

    /// Adds the window to the Space, keeping its other Spaces, and waits with a barrier.
    func add(_ window: UInt32, to space: UInt64) {
        var ids = [window]
        _ = kosmos_add_windows(space, &ids, 1, false)
        _ = kosmos_barrier(space)
    }

    /// Takes the windows out of every Space still tracked and destroys those, kills the stub,
    /// reads back that every Space the probe created is gone, and exits.
    func finish() -> Never {
        for space in created where kosmos_space_windows(space) != nil {
            var ids = [window]
            _ = kosmos_remove_windows(space, &ids, 1)
            _ = destroySpace(space)
        }
        stub.process.terminate()
        print("stub quit, its window gone: \(poll { SkyLight.rows([window]).isEmpty })")
        let left = created.filter { kosmos_space_windows($0) != nil }
        print("Spaces created: \(created.count); still there: \(left.isEmpty ? "none" : "\(left)")")
        exit(0)
    }
}

extension CGRect {
    func equalTo(_ other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

func format(_ rect: CGRect) -> String {
    String(format: "(%g, %g, %g, %g)", rect.minX, rect.minY, rect.width, rect.height)
}

func format(_ point: CGPoint) -> String { String(format: "(%g, %g)", point.x, point.y) }

func format(_ t: CGAffineTransform) -> String { String(format: "[%g %g %g %g %g %g]", t.a, t.b, t.c, t.d, t.tx, t.ty) }
