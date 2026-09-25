// kosmos-probe mission-control [seconds]: which Mission Control signals reach a process on
// macOS 27 (DESIGN.md, section 5.3)? It registers the four Exposé notifications yabai
// watches (src/mission_control.c) on the Dock, where yabai watches them, and on
// WindowManager.app, which holds Mission Control's classes on macOS 27, and prints what each
// registration returned. It also registers WindowServer event 1204, which yabai reads for
// Mission Control before macOS 12. Each arrival prints with the wall clock time, and the
// probe exits after 120 s by default. It opens no window and takes no focus. Needs
// Accessibility for the terminal; the probe never asks for it.
import AppKit
import CKosmos

@MainActor private let wallClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

@MainActor func missionControl(seconds: Double) -> Never {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    // The notifications and the event arrive in an AppKit event loop, as in Kosmos.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var observers: [AXObserver] = []
    for bundle in ["com.apple.dock", "com.apple.WindowManager"] {
        var created: AXObserver?
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier,
              AXObserverCreate(pid, { _, element, notification, _ in
                  var pid: pid_t = 0
                  AXUIElementGetPid(element, &pid)
                  arrived("pid \(pid) \(notification)")
              }, &created) == .success, let observer = created else {
            print("\(bundle): no Accessibility observer")
            continue
        }
        // As yabai names them. The Dock and WindowManager.app of macOS 27 (26A428) contain
        // the same four names.
        for notification in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"] {
            let result = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), notification as CFString, nil)
            print("\(bundle) (pid \(pid)) \(notification): "
                  + (result == .success ? "registered" : "not registered, AXError \(result.rawValue)"))
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers.append(observer)
    }
    let result = SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), { _, _, _, _, _ in arrived("WindowServer event 1204") }, 1204, nil)
    print("WindowServer event 1204: \(result == .success ? "registered" : "not registered, CGError \(result.rawValue)")")
    print("watching for \(seconds) s")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    withExtendedLifetime(observers) { app.run() }
    exit(0)
}

/// Prints `signal` with the wall clock time it arrived.
private func arrived(_ signal: String) {
    let at = Date()
    DispatchQueue.main.async { MainActor.assumeIsolated { print(wallClock.string(from: at) + " " + signal) } }
}
