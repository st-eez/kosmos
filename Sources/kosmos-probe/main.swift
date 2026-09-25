// Probes for private behaviour the design depends on. Each probe touches only windows it
// creates itself.
//
//   kosmos-probe secure-input       Which Carbon hotkeys fire while Secure Input is on, from
//                                   real key presses its window asks for (SecureInput.swift).
//   kosmos-probe mission-control [seconds]
//                                   Which Mission Control signals arrive (MissionControl.swift).
//   kosmos-probe bench-windows <count> [display] | eui [pid...]
//                                   What script/bench-relayout.sh uses (Bench.swift).
//   kosmos-probe borders | borders-cpu [relayouts]
//                                   What Kosmos's border windows need and cost (Borders.swift).
import AppKit
import CKosmos
import KosmosCore
import KosmosIPC
import KosmosRecovery
import KosmosSkyLight

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "panel": showPanel()
case "barrier": barrier(cycles: arguments.dropFirst().first.flatMap(Int.init) ?? 50)
case "survive-kill": surviveKill()
case "destroyed-space": destroyedSpace()
case "fullscreen-window": fullscreenWindow()
case "fullscreen": fullscreen()
case "departures-window": departuresWindow()
case "departures": departures()
case "tabs-window": tabsWindow()
case "tabs": tabs(conceal: arguments.dropFirst().first)
case "hidden-window": showHiddenWindow(levels: arguments.dropFirst().first == "levels")
case "reveal": reveal()
case "displays": displays()
case "secure-input": secureInput()
case "ax-child": axChild()
case "ax-timeout": axTimeout()
case "key-stub": keyStub(arguments.dropFirst().first ?? "S", Array(arguments.dropFirst(2)))
case "keying": keying(rounds: arguments.dropFirst().first.flatMap(Int.init) ?? 3, finder: arguments.contains("finder"))
case "level": levels()
case "events": events(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30)
case "key-holder": keyHolder(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30)
case "holding": holding()
case "mission-control": missionControl(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 120)
case "bench-windows" where arguments.count >= 2 && Int(arguments.dropFirst().first!) != nil:
    benchWindows(Int(arguments.dropFirst().first!)!, on: arguments.dropFirst(2).first)
case "eui": enhancedUserInterface(arguments.dropFirst().compactMap { pid_t($0) })
case "borders": borders()
case "borders-cpu": bordersCPU(relayouts: arguments.dropFirst().first.flatMap(Int.init) ?? 12)
case "border-targets" where arguments.count >= 2 && Int(arguments.dropFirst().first!) != nil:
    borderTargets(Int(arguments.dropFirst().first!)!)
default:
    print("usage: kosmos-probe barrier [cycles] | survive-kill | destroyed-space | fullscreen | departures | tabs [strip|keep] | reveal | displays | secure-input | ax-timeout | keying [rounds] [finder] | level [onscreen|opaque] | events [seconds] | key-holder [seconds] | mission-control [seconds] | holding | bench-windows <count> [display] | eui [pid...] | borders | borders-cpu [relayouts]")
    exit(2)
}
