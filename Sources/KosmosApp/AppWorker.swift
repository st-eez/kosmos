import AppKit
import CKosmos
import KosmosCore

/// What an app's worker tells the main actor. Each report is stamped on receipt, so the
/// main actor can order it against commands (DESIGN.md, section 5.4).
struct AXReport: Sendable {
    enum Kind: Sendable {
        case windowCreated(UInt32)
        case windowDestroyed(UInt32)
        case focusedWindowChanged(UInt32?)
        case minimized(UInt32, Bool)
        case titleChanged(UInt32)
        /// Frames read back after writes, with the target each write aimed for.
        case framesApplied([(id: UInt32, target: CGRect, readBack: CGRect)])
    }

    let pid: pid_t
    let kind: Kind
    let received: ContinuousClock.Instant
}

/// Accessibility facts about one window.
struct AXWindowInfo: Sendable {
    let role: String?
    let subrole: String?
    let title: String?
    let minimized: Bool
}

/// Owns one app's Accessibility elements and observer on the app's own thread. It never
/// touches the model: it reports to the main actor and answers reads.
actor AppWorker {
    let pid: pid_t
    private let executor: RunLoopExecutor
    private let report: @MainActor (AXReport) -> Void
    private let app: AXUIElement
    private var observer: AXObserver?
    private var elements: [UInt32: AXUIElement] = [:]
    /// Writes waiting for the next drain; a newer target replaces an older one.
    private var queuedWrites: [UInt32: (write: FrameWrite, target: CGRect)] = [:]
    private var drainScheduled = false

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(pid: pid_t, name: String, report: @escaping @MainActor (AXReport) -> Void) {
        self.pid = pid
        self.report = report
        executor = RunLoopExecutor(name: "kosmos.ax.\(name)")
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
    }

    /// Registers the app's observer and reads its current windows. Returns false when the
    /// app does not answer Accessibility yet.
    func start() -> Bool {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let worker = Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            // The callback runs on the worker's own run loop thread, so the element never
            // leaves it.
            nonisolated(unsafe) let element = element
            worker.assumeIsolated { $0.handle(name, element) }
        }, &observer) == .success, let observer else { return false }
        self.observer = observer
        CFRunLoopAddSource(executor.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let result = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if result != .success, result != .notificationAlreadyRegistered { return false }
        }
        for window in copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { track(window) }
        return true
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(executor.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        elements = [:]
        executor.stop()
    }

    func info(_ id: UInt32) -> AXWindowInfo? {
        guard let element = elements[id] else { return nil }
        return AXWindowInfo(role: copy(element, kAXRoleAttribute) as? String,
                            subrole: copy(element, kAXSubroleAttribute) as? String,
                            title: copy(element, kAXTitleAttribute) as? String,
                            minimized: copy(element, kAXMinimizedAttribute) as? Bool ?? false)
    }

    var windowIDs: [UInt32] { Array(elements.keys) }

    func focusedWindow() -> UInt32? {
        guard let element = copy(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        return track(element)
    }

    /// Queues frame writes from any thread, in the order of the calls. A Task per batch
    /// could run an older batch last and leave a stale frame.
    nonisolated func enqueueFrames(_ writes: [UInt32: (write: FrameWrite, target: CGRect)]) {
        executor.perform { self.assumeIsolated { $0.setFrames(writes) } }
    }

    /// The public focus path, for when the private one is off (DESIGN.md, section 5.4): makes
    /// the window its app's main window and raises it, then activates the app. The app keys a
    /// window of its own choosing, on this Mac often another one (wm-research focus note,
    /// section 4). `dropped` runs instead when a newer focus intent exists.
    nonisolated func focusPublicly(_ id: UInt32, isCurrent: @escaping @Sendable () -> Bool,
                                   dropped: @escaping @Sendable () -> Void) {
        executor.perform { self.assumeIsolated { $0.raiseAndActivate(id, isCurrent: isCurrent, dropped: dropped) } }
    }

    private func raiseAndActivate(_ id: UInt32, isCurrent: () -> Bool, dropped: () -> Void) {
        guard isCurrent() else { return dropped() }
        if let element = elements[id] {
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    /// Queues frame writes. Writes queued before the drain runs are merged, so each window
    /// gets only its newest target.
    func setFrames(_ writes: [UInt32: (write: FrameWrite, target: CGRect)]) {
        queuedWrites.merge(writes) { _, new in new }
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { self.drainWrites() }
    }

    private func drainWrites() {
        drainScheduled = false
        let writes = queuedWrites
        queuedWrites = [:]
        var results: [(id: UInt32, target: CGRect, readBack: CGRect)] = []
        for (id, entry) in writes {
            guard let element = elements[id] else { continue }
            switch entry.write {
            case .position(let origin):
                set(element, kAXPositionAttribute, origin)
            case .frame(let frame):
                set(element, kAXSizeAttribute, frame.size)
                set(element, kAXPositionAttribute, frame.origin)
                set(element, kAXSizeAttribute, frame.size)
            }
            if let readBack = frame(element) { results.append((id, entry.target, readBack)) }
        }
        if !results.isEmpty { send(.framesApplied(results)) }
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        logFailure(AXUIElementSetAttributeValue(element, attribute as CFString, value), attribute)
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        logFailure(AXUIElementSetAttributeValue(element, attribute as CFString, value), attribute)
    }

    private func logFailure(_ error: AXError, _ attribute: String) {
        // Backing off an app that times out comes with tiling on real apps.
        if error != .success { log.error("pid \(self.pid) set \(attribute, privacy: .public) failed: \(error.rawValue)") }
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = copy(element, kAXPositionAttribute), let s = copy(element, kAXSizeAttribute),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let id = track(element) { send(.windowCreated(id)) }
        case kAXFocusedWindowChangedNotification:
            send(.focusedWindowChanged(track(element)))
        case kAXUIElementDestroyedNotification:
            if let id = elements.first(where: { CFEqual($0.value, element) })?.key {
                elements[id] = nil
                send(.windowDestroyed(id))
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            if let id = windowID(element) { send(.minimized(id, notification == kAXWindowMiniaturizedNotification)) }
        case kAXTitleChangedNotification:
            if let id = windowID(element) { send(.titleChanged(id)) }
        default:
            break
        }
    }

    /// Caches a window element under its WindowServer id and observes it.
    @discardableResult
    private func track(_ element: AXUIElement) -> UInt32? {
        guard let id = windowID(element) else { return nil }
        if elements.updateValue(element, forKey: id) == nil, let observer {
            AXUIElementSetMessagingTimeout(element, 1.0)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
        }
        return id
    }

    private func windowID(_ element: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func send(_ kind: AXReport.Kind) {
        let report = AXReport(pid: pid, kind: kind, received: .now)
        let deliver = self.report
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(report) } }
    }
}
