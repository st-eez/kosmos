// kosmos-probe secure-input: which Carbon hotkeys fire while Secure Input is on, and how
// Kosmos can learn that it turned on (DESIGN.md, section 5.6).
//
// The probe registers each key below as an exclusive hotkey and presses it in three phases:
// Secure Input off, the probe's own password field focused, and another process holding
// Secure Input while the probe's plain field is focused. Every press lands in the probe's
// own window: a hotkey that fires consumes the key, and one that does not lets the key reach
// the window, where a local monitor sees it. So each press has an answer without a timeout.
// Without `keys` the probe posts synthetic presses. With `keys` its window asks the person at
// the keyboard for the keys a laptop has, in the first two phases.
//
// Secure Input ends when its holder exits (measured: WindowServer sends event 753 at the
// exit), so a crash or a kill leaves it off. The holder child exits when the probe's pipe
// closes, and both processes stop themselves with an alarm.
import AppKit
import Carbon.HIToolbox
import CKosmos

private struct TestKey {
    let name: String
    let code: Int
    /// How the window names the key.
    let label: String
    let carbon: Int
    let flags: NSEvent.ModifierFlags
    /// The interactive run asks for it: a laptop has the key, and the key stands for others.
    var asked = true

    init(_ name: String, _ carbon: Int, _ flags: NSEvent.ModifierFlags, code: Int = kVK_ANSI_Y, label: String = "Y", asked: Bool = true) {
        (self.name, self.carbon, self.flags, self.code, self.label, self.asked) = (name, carbon, flags, code, label, asked)
    }
}

/// Y with each modifier set, then Option on keys of other kinds. None of them is bound in
/// Steve's config or the sample config, or is a macOS shortcut.
private let testKeys: [TestKey] = [
    TestKey("alt-y", optionKey, [.option]),
    TestKey("alt-shift-y", optionKey | shiftKey, [.option, .shift]),
    TestKey("ctrl-y", controlKey, [.control], asked: false),
    TestKey("cmd-y", cmdKey, [.command], asked: false),
    TestKey("ctrl-alt-y", controlKey | optionKey, [.control, .option]),
    TestKey("ctrl-alt-shift-y", controlKey | optionKey | shiftKey, [.control, .option, .shift]),
    TestKey("cmd-alt-y", cmdKey | optionKey, [.command, .option]),
    TestKey("ctrl-cmd-y", controlKey | cmdKey, [.control, .command]),
    TestKey("ctrl-alt-cmd-y", controlKey | optionKey | cmdKey, [.control, .option, .command], asked: false),
    TestKey("ctrl-alt-cmd-shift-y", controlKey | optionKey | cmdKey | shiftKey, [.control, .option, .command, .shift], asked: false),
    TestKey("alt-comma", optionKey, [.option], code: kVK_ANSI_Comma, label: ","),
    TestKey("alt-space", optionKey, [.option], code: kVK_Space, label: "Space"),
    TestKey("alt-shift-space", optionKey | shiftKey, [.option, .shift], code: kVK_Space, label: "Space", asked: false),
    TestKey("alt-enter", optionKey, [.option], code: kVK_Return, label: "Return"),
    TestKey("alt-esc", optionKey, [.option], code: kVK_Escape, label: "Esc", asked: false),
    TestKey("alt-backspace", optionKey, [.option], code: kVK_Delete, label: "Delete"),
    TestKey("alt-pagedown", optionKey, [.option], code: kVK_PageDown, label: "Page Down", asked: false),
    TestKey("alt-f13", optionKey, [.option], code: kVK_F13, label: "F13", asked: false),
    TestKey("alt-keypad1", optionKey, [.option], code: kVK_ANSI_Keypad1, label: "keypad 1", asked: false),
    TestKey("alt-keypadEnter", optionKey, [.option], code: kVK_ANSI_KeypadEnter, label: "keypad Enter", asked: false),
    TestKey("f13", 0, [], code: kVK_F13, label: "F13", asked: false),
]

private enum Phase: CaseIterable {
    case off, ownField, otherProcess

    var secureInput: Bool { self != .off }

    var title: String {
        switch self {
        case .off: "off"
        case .ownField: "own password field"
        case .otherProcess: "another process"
        }
    }
}

private enum Outcome: String {
    /// The hotkey fired and consumed the key.
    case fired
    /// The key reached the probe's window: the hotkey did not fire.
    case typed
    /// Neither, within the wait: another app or macOS took the key, or it was skipped.
    case none
    /// Registration failed: another app holds the combination.
    case taken
    /// Left out of the interactive run.
    case skipped = "-"
}

private let signatureY: OSType = 0x4B53_5059   // 'KSPY'
private let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

@MainActor private var firedID: UInt32?
/// The key and modifiers of the last key down that reached the probe's window.
@MainActor private var typed: (code: Int, flags: NSEvent.ModifierFlags)?
@MainActor private var skipped = false
private let probeStart = ContinuousClock.now

private func stamp() -> String {
    // The clock starts at the first stamp, the probe's first line.
    String(format: "+%7.1f ms", elapsed(probeStart))
}

@MainActor func secureInput(_ mode: String?) -> Never {
    switch mode {
    case nil: secureInputProbe(interactive: false)
    case "keys": secureInputProbe(interactive: true)
    case "hold": holdSecureInput()
    default:
        print("usage: kosmos-probe secure-input [keys]")
        exit(2)
    }
}

/// The child that holds Secure Input for the third phase. It has no window, like a
/// background app that forgot to release it.
private func holdSecureInput() -> Never {
    alarm(600)
    EnableSecureEventInput()
    print("on")
    _ = FileHandle.standardInput.readDataToEndOfFile()
    DisableSecureEventInput()
    exit(0)
}

@MainActor private func secureInputProbe(interactive: Bool) -> Never {
    print("\(stamp()) start")
    if IsSecureEventInputEnabled() {
        print("Secure Input is already on, held by \(holderDescription()); release it and run again")
        exit(1)
    }
    if !interactive && !CGPreflightPostEventAccess() {
        print("posting key events needs Accessibility for the terminal; run `kosmos-probe secure-input keys` instead")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let previous = NSWorkspace.shared.frontmostApplication
    // A person who walks away would leave Secure Input on.
    alarm(interactive ? 600 : 60)

    print("checks with Secure Input off:")
    timeChecks()
    watchWindowServerEvents()
    let refs = registerTestKeys()
    installHotkeyHandler()
    // Test keys and Return stop here, so a press never edits a field: Return in the password
    // field ends editing, which turns Secure Input off and on again.
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let flags = event.modifierFlags.intersection(modifierMask)
        if event.keyCode == kVK_Return && flags.isEmpty {
            skipped = true
        } else if testKeys.contains(where: { $0.code == event.keyCode }) {
            typed = (Int(event.keyCode), flags)
        } else {
            return event
        }
        return nil
    }
    let window = ProbeWindow()
    window.front()

    var results: [String: [Phase: Outcome]] = [:]
    var holders: [Phase: String] = [:]
    var holder: Process?
    // Real presses check the synthetic answer; the phase with another holder answered the
    // same as the probe's own field in every synthetic run, so a person is asked for two.
    let phases: [Phase] = interactive ? [.off, .ownField] : Phase.allCases
    for phase in phases {
        switch phase {
        case .off:
            window.focus(secure: false)
        case .ownField:
            window.focus(secure: true)
            print("\(stamp()) password field focused")
            pump(until: { IsSecureEventInputEnabled() }, timeout: 1)
        case .otherProcess:
            window.focus(secure: false)
            print("\(stamp()) plain field focused")
            pump(until: { !IsSecureEventInputEnabled() }, timeout: 1)
            holder = spawnHolder()
            print("\(stamp()) holder child \(holder?.processIdentifier ?? 0) turned Secure Input on")
            pump(until: { IsSecureEventInputEnabled() }, timeout: 1)
            print("checks with Secure Input on:")
            timeChecks()
        }
        holders[phase] = IsSecureEventInputEnabled() ? "on, held by \(holderDescription())" : "off"
        print("phase \(phase.title): Secure Input \(holders[phase]!)")
        for key in testKeys {
            guard refs[key.name] != nil else {
                results[key.name, default: [:]][phase] = .taken
                continue
            }
            guard key.asked || !interactive else {
                results[key.name, default: [:]][phase] = .skipped
                continue
            }
            let outcome = interactive ? askForPress(key, phase: phase, window: window) : postPress(key, phase: phase, window: window)
            results[key.name, default: [:]][phase] = outcome
            if !interactive { print("  \(key.name): \(outcome.rawValue)") }
        }
    }

    if let holder {
        try? (holder.standardInput as? Pipe)?.fileHandleForWriting.close()
        holder.waitUntilExit()
    }
    window.close()
    for ref in refs.values { UnregisterEventHotKey(ref) }
    pump(until: { !IsSecureEventInputEnabled() }, timeout: 1)
    if let previous { previous.activate(from: .current, options: []) }

    print("")
    print("Secure Input during each phase:")
    for phase in phases { print("  \(phase.title): \(holders[phase]!)") }
    print("")
    print("Hotkeys (\(interactive ? "real key presses" : "synthetic presses posted at the HID level")):")
    let width = testKeys.map(\.name.count).max()! + 2
    print("key".padding(toLength: width, withPad: " ", startingAt: 0)
          + phases.map { $0.title.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    for key in testKeys {
        print(key.name.padding(toLength: width, withPad: " ", startingAt: 0)
              + phases.map { results[key.name]![$0]!.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    }
    print("")
    print("Secure Input after the probe: \(IsSecureEventInputEnabled() ? "ON, held by \(holderDescription())" : "off")")
    exit(0)
}

/// Runs the event loop until the condition holds or the timeout passes. Returns whether the
/// condition held.
@MainActor @discardableResult
private func pump(until condition: () -> Bool, timeout: Double) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    return true
}

@MainActor private func registerTestKeys() -> [String: EventHotKeyRef] {
    var refs: [String: EventHotKeyRef] = [:]
    for (index, key) in testKeys.enumerated() {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.code), UInt32(key.carbon), EventHotKeyID(signature: signatureY, id: UInt32(index)),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { refs[key.name] = ref } else { print("\(key.name) not registered: \(status)") }
    }
    return refs
}

@MainActor private func installHotkeyHandler() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
        var id = EventHotKeyID()
        guard let event,
              GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == signatureY
        else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated { firedID = id.id }
        return noErr
    }, 1, &pressed, nil, nil)
}

/// Prints WindowServer's Secure Input events as they arrive: 752 when it turns on and 753
/// when it turns off, whichever process changes it.
private func watchWindowServerEvents() {
    for event: UInt32 in [752, 753] {
        SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { event, _, _, _, _ in
            print("\(stamp()) WindowServer event \(event), IsSecureEventInputEnabled \(IsSecureEventInputEnabled())")
        }, event, nil)
    }
}

/// Times the check Kosmos would run and the session dictionary read that names the holder.
private func timeChecks() {
    var check: [Double] = [], holder: [Double] = []
    for _ in 0..<2000 {
        let start = ContinuousClock.now
        _ = IsSecureEventInputEnabled()
        check.append(elapsed(start) * 1000)
    }
    for _ in 0..<2000 {
        let start = ContinuousClock.now
        _ = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"]
        holder.append(elapsed(start) * 1000)
    }
    print(String(format: "  IsSecureEventInputEnabled: median %.3f µs, p95 %.3f µs", percentile(check, 0.5), percentile(check, 0.95)))
    print(String(format: "  session dictionary holder read: median %.1f µs, p95 %.1f µs", percentile(holder, 0.5), percentile(holder, 0.95)))
}

private func holderDescription() -> String {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return "no named process" }
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "no app"
    return "pid \(pid) (\(name)\(pid == getpid() ? ", this probe" : ""))"
}

@MainActor private func spawnHolder() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["secure-input", "hold"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try! process.run()
    _ = output.fileHandleForReading.readData(ofLength: 3)   // "on\n"
    return process
}

/// Posts one synthetic press, only while the probe's window is key so a press the hotkey
/// does not consume lands there.
@MainActor private func postPress(_ key: TestKey, phase: Phase, window: ProbeWindow) -> Outcome {
    guard window.isKey else {
        print("the probe's window lost focus; stopping without posting")
        exit(1)
    }
    guard IsSecureEventInputEnabled() == phase.secureInput else {
        print("Secure Input changed during phase \(phase.title); stopping")
        exit(1)
    }
    firedID = nil
    typed = nil
    // The flags a keyboard sends: each modifier with its left key's device bit, and the fn and
    // keypad flags that keys such as F13 carry and their hotkeys need to match. The event is
    // made from a private state: an event made from the HID state carries the modifier bits
    // the last key event anywhere left, and with them presses missed their hotkeys.
    var flags = CGEventFlags.maskNonCoalesced
    if key.flags.contains(.command) { flags.formUnion([.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]) }
    if key.flags.contains(.control) { flags.formUnion([.maskControl, CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))]) }
    if key.flags.contains(.option) { flags.formUnion([.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))]) }
    if key.flags.contains(.shift) { flags.formUnion([.maskShift, CGEventFlags(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))]) }
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.code), keyDown: down) else { continue }
        event.flags = event.flags.intersection([.maskSecondaryFn, .maskNumericPad]).union(flags)
        event.post(tap: .cghidEventTap)
    }
    pump(until: { firedID != nil || typed != nil }, timeout: 0.5)
    let outcome: Outcome = firedID != nil ? .fired : typed?.code == key.code ? .typed : .none
    pump(until: { false }, timeout: 0.05)   // the key up
    return outcome
}

/// Asks the person at the keyboard for one press and waits for it. Return skips the key.
@MainActor private func askForPress(_ key: TestKey, phase: Phase, window: ProbeWindow) -> Outcome {
    let asked = testKeys.filter(\.asked)
    let prompt = "Phase \(phase == .off ? 1 : 2) of 2, Secure Input \(phase.title).\n"
        + "Press \(key.name) (\(symbols(key.flags)) \(key.label)), key \(asked.firstIndex { $0.name == key.name }! + 1) "
        + "of \(asked.count). Return skips it."
    var note = ""
    while true {
        firedID = nil
        typed = nil
        skipped = false
        window.say(window.isKey ? prompt + note : "Click this window to continue.")
        pump(until: { firedID != nil || typed != nil || skipped || !window.isKey }, timeout: 600)
        if IsSecureEventInputEnabled() != phase.secureInput {
            // A click in the other field, or another app, changed it.
            window.focus(secure: phase == .ownField)
            pump(until: { IsSecureEventInputEnabled() == phase.secureInput }, timeout: 1)
            note = "\nSecure Input changed; press it again."
            continue
        }
        if skipped { return .none }
        if let id = firedID {
            if testKeys[Int(id)].name == key.name { return .fired }
            note = "\nThat was \(testKeys[Int(id)].name). Press \(key.name)."
        } else if let typed {
            if typed.code == key.code && typed.flags == key.flags { return .typed }
            let label = testKeys.first { $0.code == typed.code }!.label
            note = "\nThat was \(symbols(typed.flags)) \(label). Press \(symbols(key.flags)) \(key.label)."
        } else {
            pump(until: { window.isKey }, timeout: 600)
            window.focus(secure: phase == .ownField)
        }
    }
}

private func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
}

/// A floating panel under the pointer with a label, a plain field and a password field.
/// Kosmos leaves it alone: its level is not 0 and the probe is not a regular app.
@MainActor private final class ProbeWindow {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "")
    private let plain = NSTextField(frame: NSRect(x: 20, y: 50, width: 420, height: 24))
    private let secure = NSSecureTextField(frame: NSRect(x: 20, y: 16, width: 420, height: 24))

    init() {
        panel.title = "kosmos-probe secure-input"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        label.frame = NSRect(x: 20, y: 84, width: 420, height: 70)
        plain.placeholderString = "plain field"
        secure.placeholderString = "password field"
        for view in [label, plain, secure] { panel.contentView?.addSubview(view) }
        let pointer = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: pointer.x - 230, y: pointer.y - 85))
    }

    var isKey: Bool { NSApp.isActive && panel.isKeyWindow }

    /// Orders the panel in and makes it key the way Kosmos makes windows key.
    func front() {
        panel.orderFrontRegardless()
        _ = kosmos_make_key(getpid(), UInt32(panel.windowNumber))
        if !pump(until: { self.isKey }, timeout: 2) {
            print("the probe's window did not become key")
            exit(1)
        }
    }

    func focus(secure: Bool) {
        panel.makeFirstResponder(secure ? self.secure : plain)
    }

    func say(_ text: String) {
        label.stringValue = text
    }

    func close() {
        panel.makeFirstResponder(nil)
        panel.close()
    }
}
