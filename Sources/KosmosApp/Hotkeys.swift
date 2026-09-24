import AppKit
import Carbon.HIToolbox
import KosmosCore
import os

private let hotkeysLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "hotkeys")

/// 'KSMS'. The event handler ignores hotkeys that other code in the process registers.
private let signature: OSType = 0x4B53_4D53

/// Key bindings as Carbon hotkeys (DESIGN.md, section 5.6). WindowServer matches keys itself,
/// so a keystroke that is no binding never reaches Kosmos, and Carbon sends no repeats, so a
/// binding fires once per press. Hotkeys are registered exclusive: another app's exclusive
/// hotkey on the same combination makes registration fail and is reported, where a shared
/// registration would give the key to both apps.
///
/// Presses arrive on the main thread through the event dispatcher and go straight to the
/// handler, which should only enqueue a command.
@MainActor
final class Hotkeys: NSObject {
    struct Problem: Equatable, CustomStringConvertible {
        var mode: String
        /// The binding's combination as the config writes it.
        var key: String
        var message: String

        var description: String { "mode \(mode), \(key): \(message)" }
    }

    private(set) var mode = "main"
    private var modes: [String: [Binding]] = [:]
    private var layout: [Character: UInt16]
    /// The active mode's bindings on the current layout. A pressed key's command comes from
    /// here, so a key two modes share stays registered across a switch.
    private var table = HotkeyTable([], layout: [:])
    private var registered: [PhysicalKey: EventHotKeyRef] = [:]
    private let handler: @MainActor (Binding) -> Void
    private let layoutProblems: @MainActor ([Problem]) -> Void

    /// Installs the Carbon event handler, which keeps this object alive for the process.
    /// Create one. `layoutProblems` receives the problems after a keyboard layout change,
    /// found the way `load` finds them.
    init(layoutProblems: @escaping @MainActor ([Problem]) -> Void, handler: @escaping @MainActor (Binding) -> Void) {
        self.handler = handler
        self.layoutProblems = layoutProblems
        layout = Self.currentLayout()
        super.init()
        var pressedEvent = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            var id = EventHotKeyID()
            guard let event, let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == signature
            else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let key = PhysicalKey(hotkeyID: id.id)
            MainActor.assumeIsolated { hotkeys.pressed(key) }
            return noErr
        }, 1, &pressedEvent, Unmanaged.passRetained(self).toOpaque(), nil)
        if status != noErr { hotkeysLog.error("InstallEventHandler failed: \(status)") }

        // AppKit holds distributed notifications for an app that is not active unless they
        // are delivered immediately. Kosmos is active only while onboarding shows.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    /// Replaces every mode's bindings, as after a config load, and activates mode main. The
    /// problems are bindings macOS also uses as keyboard shortcuts, in any mode, and main's
    /// bindings that could not be registered.
    func load(_ modes: [String: [Binding]]) -> [Problem] {
        self.modes = modes
        mode = "main"
        return systemShortcutProblems() + apply()
    }

    /// Activates a mode. Only the keys the two modes do not share are unregistered and
    /// registered. The problems are the mode's bindings that could not be registered.
    func switchMode(to name: String) -> [Problem] {
        guard name == "main" || modes[name] != nil else {
            return [Problem(mode: name, key: "", message: "no mode has this name")]
        }
        mode = name
        return apply()
    }

    /// Unregisters every hotkey, to pause Kosmos. `switchMode(to: mode)` registers them again.
    func unregisterAll() {
        for key in Array(registered.keys) { unregister(key) }
        table = HotkeyTable([], layout: layout)
    }

    private func apply() -> [Problem] {
        let next = HotkeyTable(modes[mode] ?? [], layout: layout)
        var problems = next.collisions.map { collision in
            Problem(mode: mode, key: collision.dropped.key,
                    message: "is the same key as \(collision.kept.key) on the current keyboard layout and is left out")
        }
        // Changes are computed against what is registered, so a key that failed to register
        // before is tried again.
        let changes = next.changes(from: registered.keys)
        for key in changes.unregister { unregister(key) }
        table = next
        for key in changes.register {
            let status = register(key)
            guard status != noErr, let binding = next.bindings[key] else { continue }
            let message = status == OSStatus(eventHotKeyExistsErr)
                ? "another app has registered this combination"
                : "RegisterEventHotKey failed with status \(status)"
            problems.append(Problem(mode: mode, key: binding.key, message: message))
        }
        return problems
    }

    private func register(_ key: PhysicalKey) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.code), carbonModifiers(key.modifiers), key.hotkeyID,
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return status }
        registered[key] = ref
        return noErr
    }

    private func unregister(_ key: PhysicalKey) {
        guard let ref = registered.removeValue(forKey: key) else { return }
        UnregisterEventHotKey(ref)
    }

    private func pressed(_ key: PhysicalKey) {
        // A press queued before a mode switch or unregisterAll took its key out of the table
        // is dropped.
        guard let binding = table.bindings[key] else { return }
        handler(binding)
    }

    /// Bindings that macOS also uses as keyboard shortcuts. WindowServer and the Dock take
    /// those before any app's hotkey (hotkeys research, section 2).
    ///
    /// Ceiling: macOS lists arrow and function keys with the fn flag, which may mean the Globe
    /// key or only the flag those keys always carry. Kosmos never registers fn, so those
    /// shortcuts never compare equal and a clash on an arrow or function key goes unreported.
    /// A probe that settles what the flag means (hotkeys research, open question 6) would let
    /// arrows be compared with fn masked out.
    private func systemShortcutProblems() -> [Problem] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let shortcuts = list?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        var taken: Set<[Int]> = []
        for shortcut in shortcuts where shortcut[kHISymbolicHotKeyEnabled as String] as? Bool == true {
            if let code = shortcut[kHISymbolicHotKeyCode as String] as? Int,
               let modifiers = shortcut[kHISymbolicHotKeyModifiers as String] as? Int {
                taken.insert([code, modifiers & (cmdKey | shiftKey | optionKey | controlKey | Int(kEventKeyModifierFnMask))])
            }
        }
        var problems: [Problem] = []
        for (mode, bindings) in modes.sorted(by: { $0.key < $1.key }) {
            for binding in bindings {
                let key = binding.combo.physicalKey(layout: layout)
                if taken.contains([Int(key.code), Int(carbonModifiers(key.modifiers))]) {
                    problems.append(Problem(mode: mode, key: binding.key, message: "macOS uses this combination as a keyboard "
                        + "shortcut; turn the shortcut off in System Settings > Keyboard > Keyboard Shortcuts"))
                }
            }
        }
        return problems
    }

    @objc private func layoutChanged() {
        let current = Self.currentLayout()
        guard current != layout else { return }
        layout = current
        layoutProblems(systemShortcutProblems() + apply())
    }

    /// The characters the current ASCII capable layout types and their key codes. Empty when
    /// the layout has no Unicode data, and then every character key takes its place on a US
    /// keyboard.
    private static func currentLayout() -> [Character: UInt16] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue())
        else { return [:] }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            keyboardLayout(layout, keyboardType: UInt32(LMGetKbdType()))
        }
    }
}

extension PhysicalKey {
    /// The id Carbon hands back with a press. It holds the key code and the modifiers, so a
    /// press names its key.
    var hotkeyID: EventHotKeyID {
        EventHotKeyID(signature: signature, id: UInt32(code) << 8 | UInt32(modifiers.rawValue))
    }

    init(hotkeyID id: UInt32) {
        self.init(code: UInt16(truncatingIfNeeded: id >> 8), modifiers: KeyCombo.Modifiers(rawValue: UInt8(truncatingIfNeeded: id)))
    }
}

private func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
    var flags = 0
    if modifiers.contains(.cmd) { flags |= cmdKey }
    if modifiers.contains(.ctrl) { flags |= controlKey }
    if modifiers.contains(.alt) { flags |= optionKey }
    if modifiers.contains(.shift) { flags |= shiftKey }
    return UInt32(flags)
}

/// The process holding Secure Input, which a password field turns on. While it is on, some
/// bindings stop (DESIGN.md, section 5.6).
struct SecureInput: Equatable, CustomStringConvertible {
    /// The process WindowServer names. When a process with no windows of its own turns Secure
    /// Input on, WindowServer names the frontmost app instead (measured on macOS 27 with a
    /// command line probe).
    var pid: pid_t?
    var appName: String?

    /// Nil while Secure Input is off. Naming the holder, which copies the session dictionary,
    /// runs only while Secure Input is on.
    static func current() -> SecureInput? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        return SecureInput(pid: pid, appName: pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName })
    }

    var description: String {
        switch (appName, pid) {
        case let (name?, pid?): "\(name) (pid \(pid))"
        case let (nil, pid?): "pid \(pid)"
        default: "an unnamed process"
        }
    }
}
