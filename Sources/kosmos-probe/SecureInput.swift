// kosmos-probe secure-input: which Carbon hotkeys fire while Secure Input is on, and the
// WindowServer events that report it (docs/hotkeys.md). Its window asks for a real press of
// each key twice, with Secure Input off and with its password field focused; Return skips a
// key. Secure Input ends with its holder, so a crash leaves it off, and an alarm stops the
// probe after 10 minutes.
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

    init(_ name: String, _ carbon: Int, _ flags: NSEvent.ModifierFlags, code: Int = kVK_ANSI_Y, label: String = "Y") {
        (self.name, self.carbon, self.flags, self.code, self.label) = (name, carbon, flags, code, label)
    }
}

/// Y with each kind of modifier set, then Option on keys of other kinds, all on a laptop
/// keyboard. None of them is bound in Steve's config or the sample config, or is a macOS
/// shortcut.
private let testKeys: [TestKey] = [
    TestKey("alt-y", optionKey, [.option]),
    TestKey("alt-shift-y", optionKey | shiftKey, [.option, .shift]),
    TestKey("ctrl-alt-y", controlKey | optionKey, [.control, .option]),
    TestKey("ctrl-alt-shift-y", controlKey | optionKey | shiftKey, [.control, .option, .shift]),
    TestKey("cmd-alt-y", cmdKey | optionKey, [.command, .option]),
    TestKey("ctrl-cmd-y", controlKey | cmdKey, [.control, .command]),
    TestKey("alt-comma", optionKey, [.option], code: kVK_ANSI_Comma, label: ","),
    TestKey("alt-space", optionKey, [.option], code: kVK_Space, label: "Space"),
    TestKey("alt-enter", optionKey, [.option], code: kVK_Return, label: "Return"),
    TestKey("alt-backspace", optionKey, [.option], code: kVK_Delete, label: "Delete"),
]

private enum Phase: CaseIterable {
    case off, on

    var secureInput: Bool { self == .on }

    var title: String {
        switch self {
        case .off: "off"
        case .on: "password field"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Secure Input is off"
        case .on: "Secure Input is on, from this window's password field"
        }
    }
}

private enum Outcome: String {
    /// The hotkey fired and consumed the key.
    case fired
    /// The key reached the probe's window: the hotkey did not fire.
    case typed
    /// Skipped: the person pressed Return, for example because nothing happened.
    case none
    /// Registration failed: another app holds the combination.
    case taken
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

@MainActor func secureInput() -> Never {
    print("\(stamp()) start")
    if IsSecureEventInputEnabled() {
        print("Secure Input is already on, held by \(holderDescription()); release it and run again")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let previous = NSWorkspace.shared.frontmostApplication
    // A person who walks away would leave Secure Input on.
    alarm(600)

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
    for phase in Phase.allCases {
        window.focus(secure: phase == .on)
        if phase == .on {
            print("\(stamp()) password field focused")
            pump(until: { IsSecureEventInputEnabled() }, timeout: 1)
        }
        print("phase \(phase.title): Secure Input \(IsSecureEventInputEnabled() ? "on, held by \(holderDescription())" : "off")")
        for key in testKeys {
            guard refs[key.name] != nil else {
                results[key.name, default: [:]][phase] = .taken
                continue
            }
            results[key.name, default: [:]][phase] = askForPress(key, phase: phase, window: window)
        }
    }

    window.close()
    for ref in refs.values { UnregisterEventHotKey(ref) }
    pump(until: { !IsSecureEventInputEnabled() }, timeout: 1)
    if let previous { previous.activate(from: .current, options: []) }

    print("")
    print("Hotkeys:")
    let width = testKeys.map(\.name.count).max()! + 2
    print("key".padding(toLength: width, withPad: " ", startingAt: 0)
          + Phase.allCases.map { $0.title.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    for key in testKeys {
        print(key.name.padding(toLength: width, withPad: " ", startingAt: 0)
              + Phase.allCases.map { results[key.name]![$0]!.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0) }.joined())
    }
    print("")
    print("Secure Input after the probe: \(IsSecureEventInputEnabled() ? "ON, held by \(holderDescription())" : "off")")
    exit(0)
}

/// Returns whether the condition held before the timeout.
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
/// when it turns off.
private func watchWindowServerEvents() {
    for event: UInt32 in [752, 753] {
        SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { event, _, _, _, _ in
            print("\(stamp()) WindowServer event \(event), IsSecureEventInputEnabled \(IsSecureEventInputEnabled())")
        }, event, nil)
    }
}

private func holderDescription() -> String {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return "no named process" }
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "no app"
    return "pid \(pid) (\(name)\(pid == getpid() ? ", this probe" : ""))"
}

/// Asks the person at the keyboard for one press and waits for it. Return skips the key.
@MainActor private func askForPress(_ key: TestKey, phase: Phase, window: ProbeWindow) -> Outcome {
    let prompt = "Phase \(Phase.allCases.firstIndex(of: phase)! + 1) of 2: \(phase.explanation).\n"
        + "Press \(key.name) (\(symbols(key.flags)) \(key.label)), key \(testKeys.firstIndex { $0.name == key.name }! + 1) "
        + "of \(testKeys.count). Return skips it."
    var note = ""
    while true {
        firedID = nil
        typed = nil
        skipped = false
        window.say(window.isKey ? prompt + note : "Click this window to continue.")
        pump(until: { firedID != nil || typed != nil || skipped || !window.isKey }, timeout: 600)
        if IsSecureEventInputEnabled() != phase.secureInput {
            // Focus left the window, or a click moved it to the other field. The press is
            // asked for again, so every answer comes from the phase's state.
            print("\(stamp()) Secure Input changed during phase \(phase.title); asking for \(key.name) again")
            window.focus(secure: phase == .on)
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
            window.focus(secure: phase == .on)
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
