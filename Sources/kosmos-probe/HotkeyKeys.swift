// Whether the input tap can tell a hotkey's key from the user's other keys, as Kosmos's
// InputTap does (docs/focus.md).
//
//   kosmos-probe hotkey-keys [seconds]
//                                   Listen-only taps at the session and annotated session
//                                   locations record each key down, never a key code, for
//                                   `seconds`, 30 by default, while the user types and presses
//                                   hotkeys. Prints how many of his key downs (source pid 0)
//                                   reached both taps under one event time and how late the
//                                   annotated copy came, each key the session tap alone heard
//                                   (a hotkey's), keys other processes posted, and whether
//                                   Secure Input was on.
import AppKit
import Carbon

private struct KeySeen {
    let at: Double
    let event: UInt64
    let source: Int64
}

@MainActor private var session: [KeySeen] = []
@MainActor private var annotated: [KeySeen] = []

@MainActor func hotkeyKeys(seconds: Double) -> Never {
    print("Input Monitoring granted: \(CGPreflightListenEventAccess()), Secure Input on: \(IsSecureEventInputEnabled())")
    for (location, isSession) in [(CGEventTapLocation.cgSessionEventTap, true), (.cgAnnotatedSessionEventTap, false)] {
        guard let port = CGEvent.tapCreate(
            tap: location, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: { _, type, event, refcon in
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let key = KeySeen(at: uptime(), event: event.timestamp, source: event.getIntegerValueField(.eventSourceUnixProcessID))
                let isSession = refcon != nil
                MainActor.assumeIsolated { isSession ? session.append(key) : annotated.append(key) }
                return Unmanaged.passUnretained(event)
            }, userInfo: isSession ? UnsafeMutableRawPointer(bitPattern: 1) : nil)
        else {
            print("tap not created")
            exit(1)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
    print("recording key downs for \(seconds) s: type, and press hotkeys")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let start = session.first?.at ?? 0
        let copies = Dictionary(annotated.map { ($0.event, $0.at) }, uniquingKeysWith: min)
        let users = session.filter { $0.source == 0 }
        let lags = users.compactMap { key in copies[key.event].map { $0 - key.at } }.sorted()
        print("the user's key downs at the session tap: \(users.count); at both under one event time: \(lags.count)")
        if let slowest = lags.last, let first = lags.first {
            print(String(format: "annotated copy after the session's: from %.1f to %.1f ms, median %.1f ms", first, slowest, lags[lags.count / 2]))
        }
        for key in users where copies[key.event] == nil {
            print(String(format: "a hotkey's key: the session tap alone heard it, %.0f ms into the recording", key.at - start))
        }
        let posted = Dictionary(grouping: session.filter { $0.source != 0 }, by: \.source)
        for (pid, keys) in posted.sorted(by: { $0.key < $1.key }) {
            print("posted by pid \(pid): \(keys.count) key downs, \(keys.filter { copies[$0.event] != nil }.count) reached the annotated tap")
        }
        print("annotated key downs with no session copy: \(Set(annotated.map(\.event)).subtracting(session.map(\.event)).count)")
        print("Secure Input on at the end: \(IsSecureEventInputEnabled())")
        exit(0)
    }
    NSApplication.shared.run()
    exit(0)
}
