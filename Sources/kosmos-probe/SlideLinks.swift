// Whether slides on two displays at once step every display frame, as a slide on one does
// (docs/geometry.md).
//
//   kosmos-probe slide-links [slides] [mode...]
//                                   A red window of the probe's with a green ring, at the bottom
//                                   left of the built-in display and of the display left of the
//                                   main one, each slid 240 points right or back by its Space's
//                                   transform over 0.38 s. Each display's link steps its slide,
//                                   sent a quarter of a refresh after the vsync, with the ring's
//                                   layer moved in a window covering the display, as Kosmos
//                                   slides a window and its border, and the link stops at each
//                                   slide's end. Counts each slide's display frames. Each mode
//                                   runs 8 slides by default, or the modes named run alone:
//                                     built-in  the built-in display's window alone
//                                     left      the left display's window alone
//                                     both      both at once, started in one main thread turn,
//                                               as a relayout starts them
//                                   A crash leaves the Spaces, empty.
import AppKit
import CKosmos
import KosmosCore

private let linkDistance: CGFloat = 240

private enum LinksMode: String, CaseIterable {
    case builtIn = "built-in", left, both
}

/// One display link callback's step: the link's timestamp, when the step ran, and how long
/// the transform and the ring took, on CACurrentMediaTime's clock.
private struct LinkStep {
    let timestamp: Double, target: Double, stepped: Double, spent: Double
}

/// One display's window, its Space and ring, and the slides its link steps.
@MainActor private final class LinkedSlide: NSObject {
    let name: String
    private let screen: NSScreen
    private let space: UInt64
    private let window: NSWindow
    private let border = ProbeBorder()
    private let rest: CGRect, away: CGRect
    private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    private var slide: Slide?
    private var link: CADisplayLink?
    private var outward = true
    private(set) var started = 0.0
    private(set) var steps: [LinkStep] = []

    init?(_ name: String, screen: NSScreen) {
        self.name = name
        self.screen = screen
        let visible = appKitRect(screen.visibleFrame)
        rest = CGRect(x: visible.minX + 40, y: visible.maxY - 140, width: 160, height: 100)
        away = rest.offsetBy(dx: linkDistance, dy: 0)
        window = NSWindow(contentRect: appKitRect(rest), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderFrontRegardless()
        space = kosmos_float_space_create(1)
        super.init()
        guard space != 0 else {
            window.orderOut(nil)
            return nil
        }
        var ids = [UInt32(window.windowNumber)]
        kosmos_add_windows(space, &ids, 1, false)
        border.place(around: appKitRect(rest), radius: 0, color: green)
        border.window.order(.below, relativeTo: window.windowNumber)
    }

    var sliding: Bool { slide != nil }

    /// As Kosmos starts a slide: the link starts, and the ring's window covers the display.
    func begin(at now: Double) {
        started = now
        slide = outward ? .move(from: rest, to: away, at: now) : .move(from: away, to: rest, at: now)
        outward.toggle()
        let link = screen.displayLink(target: self, selector: #selector(tick))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        ring(around: slide!.from, covering: true)
    }

    private func ring(around shown: CGRect, covering: Bool) {
        guard covering else { return border.place(around: appKitRect(shown), radius: 0, color: green) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if border.window.frame != screen.frame { border.window.setFrame(screen.frame, display: false) }
        border.ring.frame = appKitRect(shown).insetBy(dx: -2, dy: -2).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        CATransaction.commit()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let (timestamp, target) = (link.timestamp, link.targetTimestamp)
        let wait = max(0, timestamp + link.duration / 4 - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated { self.step(timestamp: timestamp, target: target) }
        }
    }

    private func step(timestamp: Double, target: Double) {
        guard let slide else { return }
        let stepped = CACurrentMediaTime()
        let shown = slide.shown(at: target).frame
        kosmos_space_set_transform(space, Slide.transform(showing: shown, at: rest))
        let over = slide.isOver(at: target)
        ring(around: shown, covering: !over)
        steps.append(LinkStep(timestamp: timestamp, target: target, stepped: stepped, spent: CACurrentMediaTime() - stepped))
        guard over else { return }
        self.slide = nil
        link?.invalidate()
        link = nil
    }

    func reset() { steps = [] }

    func finish() {
        link?.invalidate()
        kosmos_space_set_transform(space, .identity)
        var ids = [UInt32(window.windowNumber)]
        kosmos_remove_windows(space, &ids, 1)
        kosmos_space_destroy(space)
        window.orderOut(nil)
        border.window.orderOut(nil)
    }
}

@MainActor func slideLinks(slides: Int, modes: [String]) -> Never {
    let named = modes.map(LinksMode.init(rawValue:))
    guard !named.contains(nil) else { usage() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let builtIn = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
          let main = NSScreen.screens.first,
          let left = NSScreen.screens.first(where: { $0.frame.maxX <= main.frame.minX }) else {
        print("error: needs the built-in display on and a display left of the main one")
        exit(1)
    }
    var made: [LinkedSlide] = []
    for (name, screen) in [("built-in", builtIn), ("left", left)] {
        guard let slide = LinkedSlide(name, screen: screen) else {
            print("error: no animation Space")
            made.forEach { $0.finish() }
            exit(1)
        }
        made.append(slide)
    }
    let (inside, beside) = (made[0], made[1])
    for (slide, screen) in [(inside, builtIn), (beside, left)] {
        print("\(slide.name): display \(screen.displayID) at \(screen.maximumFramesPerSecond) Hz, \(Int(screen.frame.width)) by \(Int(screen.frame.height)) points")
    }
    let chosen = named.isEmpty ? LinksMode.allCases : named.compactMap { $0 }
    pumpEvents(0.3)
    for mode in chosen {
        let moving: [LinkedSlide] = switch mode {
        case .builtIn: [inside]
        case .left: [beside]
        case .both: [inside, beside]
        }
        var runs: [String: [(started: Double, steps: [LinkStep])]] = [:]
        for _ in 1...slides {
            pumpEvents(0.2 + Double.random(in: 0..<(1.0 / 120)))
            let now = CACurrentMediaTime()
            for slide in moving { slide.begin(at: now) }
            while moving.contains(where: \.sliding) { pumpEvents(0.005) }
            for slide in moving {
                runs[slide.name, default: []].append((slide.started, slide.steps))
                slide.reset()
            }
        }
        for slide in moving { reportLinks(mode, slide.name, runs[slide.name] ?? []) }
    }
    made.forEach { $0.finish() }
    pumpEvents(0.1)
    exit(0)
}

/// Per display: the steps inside each slide's 0.38 s, the vsyncs no step came for, the first
/// step's delay after the start, and the steps' lateness and time.
@MainActor private func reportLinks(_ mode: LinksMode, _ name: String, _ runs: [(started: Double, steps: [LinkStep])]) {
    func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
    var inside: [Double] = [], firsts: [Double] = [], late: [Double] = [], spent: [Double] = []
    var missed = 0, total = 0
    for run in runs {
        let steps = run.steps
        guard let first = steps.first else { continue }
        let refresh = steps.count > 1 ? zip(steps, steps.dropFirst()).map { $1.timestamp - $0.timestamp }.min()! : 1.0 / 120
        inside.append(Double(steps.filter { $0.target <= run.started + Slide.moveDuration }.count))
        firsts.append(first.timestamp - run.started)
        for (a, b) in zip(steps, steps.dropFirst()) { missed += max(0, Int(((b.timestamp - a.timestamp) / refresh).rounded()) - 1) }
        total += steps.count
        late += steps.map { $0.stepped - ($0.timestamp + refresh / 4) }
        spent += steps.map(\.spent)
    }
    guard !inside.isEmpty else { return print("\(mode.rawValue), \(name): no steps") }
    print("\(mode.rawValue), \(name): \(runs.count) slides, \(total) steps, \(missed) vsyncs with no step; "
          + "steps inside the slide \(Int(percentile(inside, 0.5))) at the median, \(Int(inside.min()!)) at fewest; "
          + "first link timestamp \(ms(percentile(firsts, 0.5))) ms after the start at the median, \(ms(firsts.max()!)) at most; "
          + "a step \(ms(percentile(late, 0.5))) ms after its send time at the median, \(ms(late.max()!)) at most, "
          + "taking \(ms(percentile(spent, 0.5))) ms, \(ms(spent.max()!)) at most")
}
