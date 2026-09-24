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
        /// Frames read back after writes, with the target each write aimed for.
        case framesApplied([(id: UInt32, target: CGRect, readBack: CGRect)])
        /// The app answers Accessibility: it started, or answered again after a timeout.
        /// Reads that failed before can be made again.
        case answering
    }

    let pid: pid_t
    let kind: Kind
    let received: ContinuousClock.Instant
}

/// Accessibility facts about one window.
struct AXWindowInfo: Sendable {
    let role: String?
    let subrole: String?
    let minimized: Bool
}

/// Owns one app's Accessibility elements and observer on the app's own thread. It never
/// touches the model: it reports to the main actor and answers reads.
///
/// An app that lets a call wait out the messaging timeout is backed off: the worker makes no
/// call to it, keeps only the newest frame target of each window, and asks it for its role
/// with a 50 ms timeout every 0.5 s. When it answers, the worker writes the held frames and
/// reports `answering` (DESIGN.md, section 5.2).
actor AppWorker {
    /// Every call waits this long at most, set system wide in `Apps.start`. A call to a hung
    /// app returns kAXErrorCannotComplete 5 ms after its timeout; with none set, macOS 27
    /// waits 1.5 s (`kosmos-probe ax-timeout`).
    static let timeout: Float = 1.0

    let pid: pid_t
    private let name: String
    private let executor: RunLoopExecutor
    private let report: @MainActor (AXReport) -> Void
    private let app: AXUIElement
    private var observer: AXObserver?
    private var started = false
    private var elements: [UInt32: AXUIElement] = [:]
    /// Writes waiting for the next drain; a newer target replaces an older one.
    private var queuedWrites: [UInt32: (write: FrameWrite, target: CGRect)] = [:]
    private var drainScheduled = false
    private var backoff = AXBackoff<ContinuousClock.Instant>()
    /// Runs while `backoff` is asking.
    private var probe: CFRunLoopTimer?
    private let probeElement: AXUIElement

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(pid: pid_t, name: String, report: @escaping @MainActor (AXReport) -> Void) {
        self.pid = pid
        self.name = name
        self.report = report
        executor = RunLoopExecutor(name: "kosmos.ax.\(name)")
        app = AXUIElementCreateApplication(pid)
        probeElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(probeElement, 0.05)
    }

    /// Registers the app's observer and reads its current windows, then reports `answering`.
    /// Returns false when the app does not answer Accessibility yet.
    func start() -> Bool {
        // The launch retries and the probe can both get here.
        guard !started else { return true }
        if observer == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, { _, element, notification, refcon in
                guard let refcon else { return }
                let worker = Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue()
                let name = notification as String
                // The callback runs on the worker's own run loop thread, so the element never
                // leaves it.
                nonisolated(unsafe) let element = element
                worker.assumeIsolated { $0.handle(name, element) }
            }, &created) == .success, let created else { return false }
            observer = created
            CFRunLoopAddSource(executor.runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
        }
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let result = observe(app, notification)
            if result != .success, result != .notificationAlreadyRegistered { return false }
        }
        // A call that timed out above leaves the worker to the probe.
        guard trackWindows(), !backoff.backedOff else { return false }
        started = true
        send(.answering)
        return true
    }

    /// Tracks every window the app lists. False when the app did not answer.
    private func trackWindows() -> Bool {
        let windows: CFTypeRef?
        do { windows = try copy(app, kAXWindowsAttribute) } catch { return false }
        for window in windows as? [AXUIElement] ?? [] { track(window) }
        return true
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(executor.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        if let probe { CFRunLoopTimerInvalidate(probe) }
        observer = nil
        probe = nil
        elements = [:]
        executor.stop()
    }

    /// Nil when the window is unknown to the worker or the app did not answer. The caller
    /// keeps what it knew: an unanswered read never makes a window unmanaged.
    func info(_ id: UInt32) -> AXWindowInfo? {
        guard let element = elements[id] else { return nil }
        do {
            return AXWindowInfo(role: try copy(element, kAXRoleAttribute) as? String,
                                subrole: try copy(element, kAXSubroleAttribute) as? String,
                                minimized: try copy(element, kAXMinimizedAttribute) as? Bool ?? false)
        } catch {
            return nil
        }
    }

    var windowIDs: [UInt32] { Array(elements.keys) }

    /// The app's focused window, which is nil when it has none. The outer nil means the app
    /// did not answer, so its focus is unknown.
    func focusedWindow() -> UInt32?? {
        do {
            guard let element = try copy(app, kAXFocusedWindowAttribute) else { return .some(nil) }
            let id = track(element as! AXUIElement)
            return backoff.backedOff ? nil : .some(id)
        } catch {
            return nil
        }
    }

    /// Starts asking the app every 0.5 s, for an app that did not answer during its launch
    /// retries.
    func askLater() {
        guard !started, backoff.notStarted() else { return }
        scheduleProbe()
    }

    /// Queues frame writes from any thread, in the order of the calls. A Task per batch
    /// could run an older batch last and leave a stale frame.
    nonisolated func enqueueFrames(_ writes: [UInt32: (write: FrameWrite, target: CGRect)]) {
        executor.perform { self.assumeIsolated { $0.setFrames(writes) } }
    }

    /// The worker's part of a private focus request, as one job the focus queue waits on at
    /// most 30 ms (FocusQueue.swift). It reads the app's focused window when `readFocus`, as
    /// the app is the front process, and unless the target is key already, the shared request
    /// records the echo before the job raises a window target, as the raise can report the
    /// window key itself. Stale and late answers resolve under the request's lock
    /// (KosmosCore's KeyRequest).
    nonisolated func prepareKey(_ key: KeyWindow, readFocus: Bool, isCurrent: @escaping @Sendable () -> Bool,
                                request: SharedKeyRequest, done: @escaping @Sendable () -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                defer { done() }
                guard request.workerStarts(isCurrent: isCurrent()) else { return }
                let focused: UInt32?? = readFocus ? worker.focusedWindow() : nil
                // The generation is checked again after the read, which can be slow.
                if request.workerDecides(isCurrent: isCurrent(), alreadyKey: key.isAlreadyKey(appIsFront: readFocus, focused: focused),
                                         appWasFront: readFocus),
                   case .window(let id) = key {
                    worker.raiseWindow(id)
                }
            }
        }
    }

    /// The public focus path for a window, for when the private one is off or its call fails
    /// (DESIGN.md, section 5.4), as one job: skips a target that is key already, records the
    /// echo through `performing`, makes the window its app's main window and raises it, then
    /// activates the app. The app keys a window of its own choosing, on this Mac often another
    /// one (wm-research focus note, section 4). Each step can wait up to the timeout on a slow
    /// app, so each is preceded by a check that no newer focus intent exists: a request stale
    /// before its record does nothing, and one that turns stale after it stops and keeps the
    /// record for any report its steps cause. `dropped` gets the record's stamp when the
    /// activation fails.
    nonisolated func focusPublicly(_ id: UInt32, readFocus: Bool, isCurrent: @escaping @Sendable () -> Bool,
                                   performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                   dropped: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                let focused: UInt32?? = readFocus ? worker.focusedWindow() : nil
                guard isCurrent(), !KeyWindow.window(id).isAlreadyKey(appIsFront: readFocus, focused: focused) else { return }
                let stamp = ContinuousClock.now
                performing(stamp)
                if let element = worker.elements[id] {
                    _ = worker.ax { AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) }
                }
                guard isCurrent() else { return }
                worker.raiseWindow(id)
                guard isCurrent() else { return }
                if NSRunningApplication(processIdentifier: worker.pid)?.activate(options: []) != true { dropped(stamp) }
            }
        }
    }

    private func raiseWindow(_ id: UInt32) {
        guard let element = elements[id] else { return }
        let error = ax { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
        if error != .success, !backoff.backedOff { log.error("pid \(self.pid) raise \(id) failed: \(error.rawValue)") }
    }

    /// Queues frame writes. Writes queued before the drain runs are merged, so each window
    /// gets only its newest target.
    func setFrames(_ writes: [UInt32: (write: FrameWrite, target: CGRect)]) {
        queuedWrites.merge(writes) { queued, new in (new.write.replacing(queued.write, target: new.target), new.target) }
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { self.drainWrites() }
    }

    private func drainWrites() {
        drainScheduled = false
        guard !backoff.backedOff else { return }   // held until the app answers again
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
            // A write the app did not answer waits, with the ones after it, for the app to
            // answer again.
            if backoff.backedOff {
                queuedWrites[id] = entry
                continue
            }
            if let readBack = frame(element) { results.append((id, entry.target, readBack)) }
        }
        if !results.isEmpty { send(.framesApplied(results)) }
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        logFailure(ax { AXUIElementSetAttributeValue(element, attribute as CFString, value) }, attribute)
    }

    private func set(_ element: AXUIElement, _ attribute: String, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        logFailure(ax { AXUIElementSetAttributeValue(element, attribute as CFString, value) }, attribute)
    }

    private func logFailure(_ error: AXError, _ attribute: String) {
        guard error != .success, !backoff.backedOff else { return }   // backing off is logged once
        log.error("pid \(self.pid) set \(attribute, privacy: .public) failed: \(error.rawValue)")
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = try? copy(element, kAXPositionAttribute), let s = try? copy(element, kAXSizeAttribute),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let id = track(element) { send(.windowCreated(id)) }
        case kAXFocusedWindowChangedNotification:
            let id = track(element)
            if !backoff.backedOff { send(.focusedWindowChanged(id)) }
        case kAXUIElementDestroyedNotification:
            if let id = elements.first(where: { CFEqual($0.value, element) })?.key {
                elements[id] = nil
                send(.windowDestroyed(id))
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            if let id = id(of: element) { send(.minimized(id, notification == kAXWindowMiniaturizedNotification)) }
        default:
            break
        }
    }

    /// Caches a window element under its WindowServer id and observes it. Before the
    /// observer exists nothing is cached, so `start` still observes the window. Nor is a
    /// window cached when a registration timed out: the windows tracked again after the app
    /// answers, in `askAgain`, register it then, so its minimize is not missed for good.
    @discardableResult
    private func track(_ element: AXUIElement) -> UInt32? {
        guard let id = windowID(element) else { return nil }
        guard observer != nil else { return id }
        if elements[id] == nil {
            for notification in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification] {
                _ = observe(element, notification)
            }
            guard !backoff.backedOff else { return id }
        }
        elements[id] = element
        return id
    }

    private func observe(_ element: AXUIElement, _ notification: String) -> AXError {
        ax { AXObserverAddNotification(observer!, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque()) }
    }

    /// A tracked window's id without a round trip to the app, so a notification that arrives
    /// while the app is backed off still names its window; otherwise the app's answer.
    private func id(of element: AXUIElement) -> UInt32? {
        elements.first { CFEqual($0.value, element) }?.key ?? windowID(element)
    }

    /// Asks the app, so it waits out the timeout when the app hangs.
    private func windowID(_ element: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        return ax { _AXUIElementGetWindow(element, &id) } == .success && id != 0 ? id : nil
    }

    private struct NoAnswer: Error {}

    /// An attribute's value, or nil when it has none. Throws when the app did not answer, the
    /// element is gone, or the app is backed off.
    private func copy(_ element: AXUIElement, _ attribute: String) throws(NoAnswer) -> CFTypeRef? {
        var value: CFTypeRef?
        switch ax({ AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw NoAnswer()
        }
    }

    /// Makes one Accessibility call, unless the app is backed off. A call that waited out at
    /// least half the timeout backs the app off. An app still launching fails in under 9 ms
    /// (`kosmos-probe ax-timeout`) and is left to the launch retries.
    private func ax(_ call: () -> AXError) -> AXError {
        guard !backoff.backedOff else { return .cannotComplete }
        let start = ContinuousClock.now
        let result = call()
        if result == .cannotComplete, ContinuousClock.now - start > .seconds(Double(Self.timeout) / 2) {
            log.notice("\(self.name, privacy: .public) did not answer Accessibility in \(Self.timeout, format: .fixed(precision: 1)) s; asking every 0.5 s")
            if backoff.timedOut(at: start) { scheduleProbe() }
        }
        return result
    }

    private func scheduleProbe() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0) { [weak self] _ in
            self?.assumeIsolated { $0.askAgain() }
        }
        CFRunLoopAddTimer(executor.runLoop, timer, .defaultMode)
        probe = timer
    }

    /// One read with a 50 ms timeout. Any answer lets calls go again. A worker that has not
    /// started starts; one that has tracks the windows created meanwhile and writes the held
    /// frames. If none of those calls timed out and the worker has started, asking stops and
    /// the worker reports `answering`, which `start` also does. Focus changes the worker could
    /// not read meanwhile, such as a Command-Tab to the app, are lost, so while the app is the
    /// front process its focused window is reported as a key window report.
    private func askAgain() {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(probeElement, kAXRoleAttribute as CFString, &value) != .cannotComplete else { return }
        let since = backoff.answered()
        let wasStarted = started
        if wasStarted {
            _ = trackWindows()
            drainWrites()
        } else {
            _ = start()
        }
        guard backoff.settled(started: started) else { return }   // asked again at the next tick
        if let probe { CFRunLoopTimerInvalidate(probe) }
        probe = nil
        if wasStarted { send(.answering) }
        if kosmos_front_pid() == pid, let window = focusedWindow() { send(.focusedWindowChanged(window)) }
        if let since {
            log.notice("\(self.name, privacy: .public) answers Accessibility again after \((ContinuousClock.now - since).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public)")
        }
    }

    private func send(_ kind: AXReport.Kind) {
        let report = AXReport(pid: pid, kind: kind, received: .now)
        let deliver = self.report
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(report) } }
    }
}
