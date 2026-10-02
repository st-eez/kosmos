// Probes for private behaviour the design depends on. Each probe touches only windows it
// creates itself, and the header of its file says what it measures.
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

/// Each probe with its usage, then the children the probes run, which have none.
let commands: [(name: String, usage: String?, run: @MainActor ([String]) -> Void)] = [
    ("barrier", "barrier [cycles]", { barrier(cycles: $0.first.flatMap(Int.init) ?? 50) }),
    ("survive-kill", "survive-kill", { _ in surviveKill() }),
    ("destroyed-space", "destroyed-space", { _ in destroyedSpace() }),
    ("reveal", "reveal", { _ in reveal() }),
    ("holding", "holding", { _ in holding() }),
    ("handover", "handover", { _ in handover() }),
    ("concealed-move", "concealed-move [onscreen]", { concealedMove(onscreen: $0.contains("onscreen")) }),
    ("fullscreen", "fullscreen [dry]", { fullscreen(dry: $0.contains("dry")) }),
    ("departures", "departures", { _ in departures() }),
    ("tabs", "tabs [strip|keep]", { tabs(conceal: $0.first) }),
    ("level", "level [onscreen|opaque]", { levels($0) }),
    ("events", "events [seconds]", { events(seconds: $0.first.flatMap(Double.init) ?? 30) }),
    ("policy", "policy [rounds] [bundle] [titled]", {
        policy(rounds: $0.first.flatMap(Int.init) ?? 4, bundled: $0.contains("bundle"), titled: $0.contains("titled"))
    }),
    ("policy-exits", "policy-exits [cycles] [tuple]", {
        policyExits(cycles: $0.first.flatMap(Int.init) ?? 300, tuple: $0.contains("tuple"))
    }),
    ("keying", "keying [rounds] [finder]", { keying(rounds: $0.first.flatMap(Int.init) ?? 3, finder: $0.contains("finder")) }),
    ("key-holder", "key-holder [seconds]", { keyHolder(seconds: $0.first.flatMap(Double.init) ?? 30) }),
    ("input-source", "input-source [seconds] [hid]", {
        inputSource(seconds: $0.first.flatMap(Double.init) ?? 20, hid: $0.contains("hid"))
    }),
    ("ax-timeout", "ax-timeout", { _ in axTimeout() }),
    ("displays", "displays", { _ in displays() }),
    ("secure-input", "secure-input", { _ in secureInput() }),
    ("mission-control", "mission-control [seconds]", { missionControl(seconds: $0.first.flatMap(Double.init) ?? 120) }),
    ("bench-windows", "bench-windows <count> [display] [--colors] [--slow <ms>]", { arguments in
        guard let count = arguments.first.flatMap(Int.init) else { usage() }
        var rest = Array(arguments.dropFirst()), slow = 0.0
        if let flag = rest.firstIndex(of: "--slow") {
            guard flag + 1 < rest.count, let ms = Double(rest[flag + 1]) else { usage() }
            slow = ms
            rest.removeSubrange(flag...flag + 1)
        }
        benchWindows(count, on: rest.first { $0 != "--colors" }, colors: rest.contains("--colors"), slow: slow)
    }),
    ("bench-frames", "bench-frames <directory> <display> [real]", { arguments in
        guard arguments.count >= 2 else { usage() }
        benchFrames(arguments[0], display: arguments[1], real: arguments.dropFirst(2).first == "real")
    }),
    ("eui", "eui [pid...]", { enhancedUserInterface($0.compactMap { pid_t($0) }) }),
    ("borders", "borders", { _ in borders() }),
    ("constraints", "constraints", { _ in constraints() }),
    ("border-space", "border-space", { _ in borderSpace() }),
    ("borders-cpu", "borders-cpu [relayouts]", { bordersCPU(relayouts: $0.first.flatMap(Int.init) ?? 12) }),
    ("border-hop", "border-hop [one|per-display] [hops]", {
        borderHop(perDisplay: $0.first == "per-display", hops: $0.dropFirst().first.flatMap(Int.init) ?? 8)
    }),
    ("display-clamp", "display-clamp [trials] [later]", {
        displayClamp(trials: $0.first.flatMap(Int.init) ?? 10, later: $0.contains("later"))
    }),
    ("slide-sync", "slide-sync [slides] [mode...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        slideSync(slides: count ?? 6, modes: Array(arguments.dropFirst(count == nil ? 0 : 1)))
    }),
    ("slide-landing", "slide-landing [landings] [--size] [mode...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        let rest = arguments.dropFirst(count == nil ? 0 : 1)
        slideLanding(landings: count ?? 16, sizes: rest.contains("--size"), modes: rest.filter { $0 != "--size" })
    }),
    ("reveal-slide", "reveal-slide [trials] [mode...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        revealSlide(trials: count ?? 10, modes: Array(arguments.dropFirst(count == nil ? 0 : 1)))
    }),
    ("ca-lock", "ca-lock [trials] [busy]", { caLock(trials: $0.first.flatMap(Int.init) ?? 20, busy: $0.contains("busy")) }),
    ("slide-links", "slide-links [slides] [mode...]", { arguments in
        let count = arguments.first.flatMap(Int.init)
        slideLinks(slides: count ?? 8, modes: Array(arguments.dropFirst(count == nil ? 0 : 1)))
    }),
    ("border-watch", "border-watch <window> [seconds]", { arguments in
        guard let window = arguments.first.flatMap(UInt32.init) else { usage() }
        borderWatch(window, seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 60)
    }),
    ("api-sweep", "api-sweep [--list] [--check] [--out <path>] [--from <i>] [--to <i>]", { apiSweep($0) }),
    ("api-sweep-window", nil, { _ in apiSweepWindow() }),
    ("api-sweep-call", nil, { arguments in
        guard arguments.count >= 2, let index = Int(arguments[0]), let window = UInt32(arguments[1]) else { usage() }
        apiSweepCall(index: index, window: window)
    }),
    ("panel", nil, { _ in showPanel() }),
    ("clamp-window", nil, { _ in clampWindow() }),
    ("hidden-window", nil, { _ in showHiddenWindow() }),
    ("handover-creator", nil, { arguments in
        guard let window = arguments.first.flatMap(UInt32.init) else { usage() }
        handoverCreator(window, kill: arguments.contains("kill"))
    }),
    ("landing-window", nil, { _ in landingWindow() }),
    ("reveal-window", nil, { _ in revealWindow() }),
    ("moving-window", nil, { movingWindow(onscreen: $0.contains("onscreen")) }),
    ("policy-window", nil, {
        policyWindow(titled: $0.contains("titled"), early: $0.contains("early"), exitsRegular: $0.contains("regular"))
    }),
    ("policy-flips", nil, { arguments in
        let policies = arguments.compactMap { name in
            [NSApplication.ActivationPolicy.regular, .accessory, .prohibited].first { policyName($0) == name }
        }
        policyFlips(policies, atOnce: arguments.contains("at-once"))
    }),
    ("level-window", nil, { levelWindow(onscreen: $0.contains("onscreen"), opaque: $0.contains("opaque")) }),
    ("fullscreen-window", nil, { fullscreenWindow(dry: $0.contains("dry")) }),
    ("departures-window", nil, { _ in departuresWindow() }),
    ("tabs-window", nil, { _ in tabsWindow() }),
    ("ax-child", nil, { _ in axChild() }),
    ("input-poster", nil, { arguments in
        guard arguments.count >= 2, let parent = pid_t(arguments[0]) else { usage() }
        let point = arguments.count >= 4 ? Double(arguments[2]).flatMap { x in Double(arguments[3]).map { CGPoint(x: x, y: $0) } } : nil
        inputPoster(parent: parent, mode: arguments[1], point: point)
    }),
    ("key-stub", nil, { keyStub($0.first ?? "S", Array($0.dropFirst())) }),
    ("border-targets", nil, { arguments in
        guard let count = arguments.first.flatMap(Int.init) else { usage() }
        borderTargets(count)
    }),
]

func usage() -> Never {
    print("usage: kosmos-probe " + commands.compactMap(\.usage).joined(separator: " | "))
    exit(2)
}

guard let command = commands.first(where: { $0.name == CommandLine.arguments.dropFirst().first }) else { usage() }
command.run(Array(CommandLine.arguments.dropFirst(2)))
