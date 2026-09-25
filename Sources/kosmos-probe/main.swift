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
    ("fullscreen", "fullscreen [dry]", { fullscreen(dry: $0.contains("dry")) }),
    ("departures", "departures", { _ in departures() }),
    ("tabs", "tabs [strip|keep]", { tabs(conceal: $0.first) }),
    ("level", "level [onscreen|opaque]", { levels($0) }),
    ("events", "events [seconds]", { events(seconds: $0.first.flatMap(Double.init) ?? 30) }),
    ("keying", "keying [rounds] [finder]", { keying(rounds: $0.first.flatMap(Int.init) ?? 3, finder: $0.contains("finder")) }),
    ("key-holder", "key-holder [seconds]", { keyHolder(seconds: $0.first.flatMap(Double.init) ?? 30) }),
    ("ax-timeout", "ax-timeout", { _ in axTimeout() }),
    ("displays", "displays", { _ in displays() }),
    ("secure-input", "secure-input", { _ in secureInput() }),
    ("mission-control", "mission-control [seconds]", { missionControl(seconds: $0.first.flatMap(Double.init) ?? 120) }),
    ("bench-windows", "bench-windows <count> [display]", { arguments in
        guard let count = arguments.first.flatMap(Int.init) else { usage() }
        benchWindows(count, on: arguments.dropFirst().first)
    }),
    ("eui", "eui [pid...]", { enhancedUserInterface($0.compactMap { pid_t($0) }) }),
    ("borders", "borders", { _ in borders() }),
    ("borders-cpu", "borders-cpu [relayouts]", { bordersCPU(relayouts: $0.first.flatMap(Int.init) ?? 12) }),
    ("panel", nil, { _ in showPanel() }),
    ("hidden-window", nil, { _ in showHiddenWindow() }),
    ("level-window", nil, { levelWindow(onscreen: $0.contains("onscreen"), opaque: $0.contains("opaque")) }),
    ("fullscreen-window", nil, { fullscreenWindow(dry: $0.contains("dry")) }),
    ("departures-window", nil, { _ in departuresWindow() }),
    ("tabs-window", nil, { _ in tabsWindow() }),
    ("ax-child", nil, { _ in axChild() }),
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
