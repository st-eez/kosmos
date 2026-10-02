// What tells a dialog from an app's main window, read from every regular app's windows and
// never touched (docs/inventory.md).
//
//   kosmos-probe window-kinds   Each window at level 0 with no parent that its regular app's
//                               Accessibility window list names: its subrole, title and
//                               AXIdentifier, whether its close, minimize, zoom and fullscreen
//                               buttons exist and are enabled, whether AXSize is settable, the
//                               smallest and largest size WindowServer holds it to, what
//                               Kosmos does with it before any rule, what reading the zoom
//                               button and the title costs, and what observing the title's
//                               changes costs, an AXTitleChanged registration with its removal.
//                               The list leaves out windows on a Space no display shows, as
//                               behind a native fullscreen Space.
import AppKit
import CKosmos
import KosmosCore
import KosmosSkyLight

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Nil for no button, as the worker reads the zoom button.
private func enabled(_ window: AXUIElement, _ button: String) -> Bool? {
    guard let element = attribute(window, button) else { return nil }
    return attribute(element as! AXUIElement, kAXEnabledAttribute) as? Bool
}

private func describe(_ enabled: Bool?) -> String { enabled.map { $0 ? "on" : "off" } ?? "-" }

/// The median of 20 runs, in milliseconds.
private func median(_ body: () -> Void) -> String {
    var runs: [Double] = []
    for _ in 0..<20 {
        let start = ContinuousClock.now
        body()
        runs.append(elapsed(start))
    }
    return String(format: "%.3f", percentile(runs, 0.5))
}

private func settable(_ element: AXUIElement, _ name: String) -> String {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return "?" }
    return settable.boolValue ? "yes" : "no"
}

private func describe(_ size: CGSize) -> String {
    size.width > 99_999 || size.height > 99_999 ? "unbounded" : "\(Int(size.width))x\(Int(size.height))"
}

/// Each window's constraints as the row iterator reads them, then as its package keeps them
/// when the row holds none (docs/geometry.md).
private func constraints(_ id: UInt32) -> String {
    var minimum = CGSize.zero, maximum = CGSize.zero, current = CGSize.zero
    if let query = SLSWindowQueryWindows(SkyLight.connection, [id] as CFArray, 1) {
        defer { query.release() }
        if let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) {
            defer { iterator.release() }
            if SLSWindowIteratorAdvance(iterator.takeUnretainedValue()) {
                _ = SLSWindowIteratorGetConstraints(iterator.takeUnretainedValue(), &minimum, &maximum, &current)
            }
        }
    }
    if minimum == .zero, maximum == .zero {
        _ = SLSPackagesGetWindowConstraints(SkyLight.connection, id, &minimum, &maximum, &current)
    }
    return "\(describe(minimum)) | \(describe(maximum))"
}

@MainActor func windowKinds() {
    guard AXIsProcessTrusted() else { print("this terminal needs Accessibility permission"); exit(1) }
    print("app | id | subrole | title | identifier | close min zoom full | size settable | ws min | ws max | kosmos | zoom read ms | title read ms | title watch ms")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Never added to a run loop, so it hears nothing.
        var observer: AXObserver?
        _ = AXObserverCreate(app.processIdentifier, { _, _, _, _ in }, &observer)
        var windows: [UInt32: AXUIElement] = [:]
        for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            var id: UInt32 = 0
            if _AXUIElementGetWindow(window, &id) == .success { windows[id] = window }
        }
        let rows = (SkyLight.rows(Array(windows.keys)) ?? []).filter { $0.parent == 0 && $0.level == 0 }
        for row in rows.sorted(by: { $0.id < $1.id }) {
            let window = windows[row.id]!
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            let identifier = attribute(window, kAXIdentifierAttribute) as? String
            let zoom = enabled(window, kAXZoomButtonAttribute)
            let kosmos = subrole != kAXStandardWindowSubrole ? "not managed"
                : WindowRule.floats(nil, axIdentifier: identifier, zoomButtonEnabled: zoom).map { "floats \($0.rawValue)" } ?? "tiles"
            let zoomRead = median { _ = enabled(window, kAXZoomButtonAttribute) }
            let titleRead = median { _ = attribute(window, kAXTitleAttribute) }
            let titleWatch = observer.map { observer in
                median {
                    _ = AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, nil)
                    _ = AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString)
                }
            } ?? "-"
            let buttons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
                .map { describe(enabled(window, $0)) }.joined(separator: " ")
            print("""
                \(app.localizedName ?? "pid \(app.processIdentifier)") | \(row.id) | \(subrole ?? "-") | \
                \(attribute(window, kAXTitleAttribute) as? String ?? "-") | \(identifier ?? "-") | \(buttons) | \
                \(settable(window, kAXSizeAttribute)) | \(constraints(row.id)) | \(kosmos) | \
                \(zoomRead) | \(titleRead) | \(titleWatch)
                """)
        }
    }
}
