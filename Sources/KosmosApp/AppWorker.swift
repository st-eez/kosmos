import AppKit
import CKosmos
import KosmosCore
import Synchronization

/// Stamped on receipt, so the main actor can order it against commands (docs/focus.md).
struct AXReport: Sendable {
    enum Kind: Sendable {
        case windowCreated(UInt32)
        case windowDestroyed(UInt32)
        /// The key window: the focused window of the app that is front.
        case focusedWindowChanged(UInt32?)
        /// The focused window of an app that is not front, as after AXRaise in it: no key
        /// window report, but it can be Kosmos's echo.
        case backgroundFocus(UInt32?)
        case minimized(UInt32, Bool)
        case framesApplied([(id: UInt32, target: CGRect, readBack: CGRect)])
        /// Windows whose frame writes the worker dropped, as it knows no element for them.
        case framesDropped([UInt32])
        /// The app started, or answers again after a timeout: reads that failed can be made again.
        case answering
    }

    let pid: pid_t
    let kind: Kind
    let received: ContinuousClock.Instant
}

struct AXWindowInfo: Sendable {
    let role: String?
    let subrole: String?
    var minimized: Bool
}

/// One app's Accessibility elements and observer, on a thread of the app's own, so a hung app
/// blocks only itself. An app that waits out the timeout is backed off (docs/geometry.md).
actor AppWorker {
    /// Set system wide in `Apps.start`. With none set, macOS 27 waits 1.5 s on a hung app
    /// (docs/overview.md, section 2).
    static let timeout: Float = 1.0
    /// A raise that outlasts this still counts as made and can still land (docs/focus.md).
    /// No measurement chose the 5 s.
    static let raiseTimeout: Float = 5.0

    let pid: pid_t
    private let name: String
    private let executor: RunLoopExecutor
    /// Apart from the worker's calls, so a focus notification is stamped and checked against
    /// the front process without waiting behind them (docs/focus.md; tla/README.md, change 19).
    private let observerLoop: RunLoopExecutor
    private let report: @MainActor (AXReport) -> Void
    private let app: AXUIElement
    private var observer: AXObserver?
    private var started = false
    private(set) var startFailure = "no answer"
    private var elements: [UInt32: AXUIElement] = [:]
    private var queuedWrites: [UInt32: (write: FrameWrite, target: CGRect)] = [:]
    private var drainScheduled = false
    private var backoff = AXBackoff()
    /// `backoff.backedOff`, for the main actor (Controller.motions).
    private nonisolated let backedOff = Atomic(false)
    private var askTimer: CFRunLoopTimer?
    private let askElement: AXUIElement

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(pid: pid_t, name: String, report: @escaping @MainActor (AXReport) -> Void) {
        self.pid = pid
        self.name = name
        self.report = report
        executor = RunLoopExecutor(name: "kosmos.ax.\(name)")
        observerLoop = RunLoopExecutor(name: "kosmos.ax.\(name).observer")
        app = AXUIElementCreateApplication(pid)
        askElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(askElement, 0.05)
    }

    /// False while the app does not answer Accessibility yet.
    func start() -> Bool {
        guard !started else { return true }
        if observer == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, { _, element, notification, refcon in
                guard let refcon else { return }
                Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue().observed(notification as String, element)
            }, &created) == .success, let created else { startFailure = "observer not created"; return false }
            observer = created
            CFRunLoopAddSource(observerLoop.runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
        }
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let result = observe(app, notification)
            if result != .success, result != .notificationAlreadyRegistered {
                startFailure = "\(notification) not registered, AXError \(result.rawValue)"
                return false
            }
        }
        // A call that timed out above leaves the worker to askAgain.
        guard trackWindows(), !backoff.backedOff else {
            startFailure = backoff.backedOff ? "timed out" : "window list not read"
            return false
        }
        started = true
        reportAnswering()
        return true
    }

    /// The focused window follows `answering`: a focus change the worker could not read is
    /// lost otherwise (docs/geometry.md).
    private func reportAnswering() {
        send(.answering)
        guard let window = focusedWindow() else { return }
        send(kosmos_front_pid() == pid ? .focusedWindowChanged(window) : .backgroundFocus(window))
    }

    /// False when the app did not answer.
    private func trackWindows() -> Bool {
        let windows: CFTypeRef?
        do { windows = try copy(app, kAXWindowsAttribute) } catch { return false }
        for window in windows as? [AXUIElement] ?? [] { track(window) }
        return true
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(observerLoop.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        if let askTimer { CFRunLoopTimerInvalidate(askTimer) }
        observer = nil
        askTimer = nil
        elements = [:]
        observerLoop.stop()
        executor.stop()
    }

    /// Answers for no window before the worker starts, so a window is admitted only after its
    /// app's focused window is reported (docs/geometry.md).
    func info(_ ids: [UInt32]) -> [UInt32: AXWindowInfo] {
        guard started else { return [:] }
        if ids.contains(where: { elements[$0] == nil }) { _ = trackWindows() }
        var infos: [UInt32: AXWindowInfo] = [:]
        for id in ids { infos[id] = info(id) }
        return infos
    }

    private func info(_ id: UInt32) -> AXWindowInfo? {
        guard let element = elements[id] else { return nil }
        do {
            return AXWindowInfo(role: try copy(element, kAXRoleAttribute) as? String,
                                subrole: try copy(element, kAXSubroleAttribute) as? String,
                                minimized: try copy(element, kAXMinimizedAttribute) as? Bool ?? false)
        } catch {
            return nil
        }
    }

    nonisolated var answers: Bool { !backedOff.load(ordering: .relaxed) }

    /// The outer nil means the app did not answer; the inner nil, that it has no focused window.
    func focusedWindow() -> UInt32?? {
        do {
            guard let element = try copy(app, kAXFocusedWindowAttribute) else { return .some(nil) }
            let id = track(element as! AXUIElement)
            return backoff.backedOff ? nil : .some(id)
        } catch {
            return nil
        }
    }

    func askLater() {
        guard !started, backoff.notStarted() else { return }
        startAsking()
    }

    /// In call order: a Task per batch could run an older batch last and leave a stale frame.
    nonisolated func enqueueFrames(_ writes: [UInt32: (write: FrameWrite, target: CGRect)]) {
        executor.perform { self.assumeIsolated { $0.setFrames(writes) } }
    }

    /// The split model's `WorkerStart`, `WorkerRead` and `WorkerRaise` (KosmosCore's
    /// KeyRequest). `performing` records the echo just before AXRaise (docs/focus.md).
    nonisolated func focusPrivately(_ id: UInt32, isCurrent: @escaping @Sendable () -> Bool, request: KeyRequest,
                                    performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                    forgetRecord: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                    done: @escaping @Sendable () -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                defer { done() }
                guard request.workerStarts(isCurrent: isCurrent()) else { return }
                let focused = worker.focusedWindow()
                if focused == nil { worker.logUnanswered(id) }
                guard request.workerRead(isCurrent: isCurrent(), focused: focused, target: id),
                      worker.elements[id] != nil,
                      request.workerRaises(isCurrent: isCurrent(), appIsFront: kosmos_front_pid() == worker.pid)
                else { return }
                let stamp = ContinuousClock.now
                performing(stamp)
                if !worker.raiseWindow(id) { forgetRecord(stamp) }
            }
        }
    }

    /// `WorkerPost` (KosmosCore's KeyRequest): the key record leaves the window where it sits
    /// in its app's stacking order, and this raise brings it up (docs/focus.md).
    ///
    /// Ceiling: `raised` can reach the main actor before the raise's report, which then reads
    /// as the user's choice. Forgetting the record only once the observer has handled the
    /// app's earlier notifications would close that (docs/focus.md).
    nonisolated func raiseAfterKeyRecord(_ id: UInt32, performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                         raised: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                let focused = worker.focusedWindow()
                let front = kosmos_front_pid() == worker.pid
                guard worker.elements[id] != nil,
                      KeyRequest.workerPostRaises(appIsFront: front, focused: focused, target: id) else {
                    // Tells a read that beat the key record from the user moving on (docs/focus.md).
                    let seen = focused.map { $0.map(String.init) ?? "none" } ?? "no answer"
                    log.info("\(worker.name, privacy: .public) raise after the key record of \(id) skipped: front \(front), focused \(seen, privacy: .public)")
                    return
                }
                let stamp = ContinuousClock.now
                performing(stamp)
                worker.raiseWindow(id)
                _ = worker.focusedWindow()
                raised(stamp)
            }
        }
    }

    /// The public path, where the app chooses its key window (docs/focus.md). Each step can
    /// wait out the timeout, so each first checks the request is current; one that went stale
    /// after its record keeps the record for the reports its steps cause.
    nonisolated func focusPublicly(_ id: UInt32, readFocus: Bool, isCurrent: @escaping @Sendable () -> Bool,
                                   performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                   forgetRecord: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                let focused: UInt32?? = readFocus ? worker.focusedWindow() : nil
                if readFocus, focused == nil { worker.logUnanswered(id) }
                guard isCurrent(), focusGoesAhead(to: id, appIsFront: readFocus, focused: focused) else { return }
                let stamp = ContinuousClock.now
                performing(stamp)
                if let element = worker.elements[id] {
                    _ = worker.ax { AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) }
                }
                guard isCurrent() else { return }
                worker.raiseWindow(id)
                guard isCurrent() else { return }
                if NSRunningApplication(processIdentifier: worker.pid)?.activate(options: []) != true { forgetRecord(stamp) }
            }
        }
    }

    private func logUnanswered(_ id: UInt32) {
        log.notice("\(self.name, privacy: .public) did not answer the focused window read; focus on \(id) stops")
    }

    /// False when no raise can land: the app refused it or failed at once, or no call was made.
    /// A raise that timed out can still land, and counts as made.
    @discardableResult
    private func raiseWindow(_ id: UInt32) -> Bool {
        guard let element = elements[id] else { return false }
        AXUIElementSetMessagingTimeout(element, Self.raiseTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }   // back to the system wide timeout
        let start = ContinuousClock.now
        let error = ax { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
        let waitedOut = error == .cannotComplete && ContinuousClock.now - start > .seconds(Double(Self.raiseTimeout) / 2)
        if waitedOut {
            log.error("\(self.name, privacy: .public) did not perform the raise of \(id) in \(Self.raiseTimeout, format: .fixed(precision: 1)) s; it can still land")
        } else if error != .success, !backoff.backedOff {
            log.error("pid \(self.pid) raise \(id) failed: \(error.rawValue)")
        }
        return error == .success || waitedOut
    }

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
        var dropped: [UInt32] = []
        for (id, entry) in writes {
            guard let element = elements[id] else {
                dropped.append(id)
                continue
            }
            let start = ContinuousClock.now
            switch entry.write {
            case .position(let origin):
                set(element, kAXPositionAttribute, origin)
            case .frame(let frame):
                set(element, kAXSizeAttribute, frame.size)
                set(element, kAXPositionAttribute, frame.origin)
                set(element, kAXSizeAttribute, frame.size)
            }
            // Kept for the next drain: when the app answers again, or at its next frame write.
            guard !backoff.backedOff, var readBack = frame(element) else {
                queuedWrites[id] = entry
                continue
            }
            // A height AppKit ignored near a display edge lands through one 40 pt shorter; a
            // window still taller refused the height (docs/geometry.md).
            if case .frame(let target) = entry.write, readBack.height > target.height + FrameLedger.slack {
                let kept = readBack.height
                set(element, kAXSizeAttribute, CGSize(width: target.width, height: target.height - 40))
                set(element, kAXSizeAttribute, target.size)
                guard !backoff.backedOff, let retried = frame(element) else {
                    queuedWrites[id] = entry
                    continue
                }
                readBack = retried
                log.info("\(id) kept height \(Int(kept)) of \(Int(target.height)); written again through a shorter one: \(Int(readBack.height))")
            }
            // script/bench-relayout.sh counts these lines.
            log.info("\(id) written, AX time \((ContinuousClock.now - start).milliseconds, format: .fixed(precision: 2)) ms")
            results.append((id, entry.target, readBack))
        }
        if !dropped.isEmpty {
            log.notice("\(self.name, privacy: .public) frame writes dropped for \(dropped.map(String.init).joined(separator: " "), privacy: .public): no element")
            send(.framesDropped(dropped))
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

    /// On the observer's thread: a focus change is stamped and checked against the front
    /// process before anything that can wait on the app (tla/Kosmos.tla, Observe).
    private nonisolated func observed(_ notification: String, _ element: AXUIElement) {
        nonisolated(unsafe) let element = element
        if notification == kAXFocusedWindowChangedNotification {
            let received = ContinuousClock.now
            let front = kosmos_front_pid() == pid
            var id: UInt32 = 0
            let window: UInt32? = _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
            deliver(AXReport(pid: pid, kind: front ? .focusedWindowChanged(window) : .backgroundFocus(window), received: received))
        }
        executor.perform { self.assumeIsolated { $0.handle(notification, element) } }
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let id = track(element) { send(.windowCreated(id)) }
        case kAXFocusedWindowChangedNotification:
            track(element)   // reported by `observed`
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

    /// Caches nothing before the observer exists or when a registration timed out, so a later
    /// track registers the window's notifications again and no minimize is missed for good.
    @discardableResult
    private func track(_ element: AXUIElement) -> UInt32? {
        guard let id = id(of: element) else { return nil }
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

    /// A tracked window's id needs no round trip, so a notification during a backoff still
    /// names its window.
    private func id(of element: AXUIElement) -> UInt32? {
        elements.first { CFEqual($0.value, element) }?.key ?? windowID(element)
    }

    private func windowID(_ element: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        return ax { _AXUIElementGetWindow(element, &id) } == .success && id != 0 ? id : nil
    }

    private struct NoAnswer: Error {}

    private func copy(_ element: AXUIElement, _ attribute: String) throws(NoAnswer) -> CFTypeRef? {
        var value: CFTypeRef?
        switch ax({ AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw NoAnswer()
        }
    }

    /// An app still launching fails in under 9 ms, so only a call that waited out half the
    /// timeout backs its app off (docs/geometry.md).
    private func ax(_ call: () -> AXError) -> AXError {
        guard !backoff.backedOff else { return .cannotComplete }
        let start = ContinuousClock.now
        let result = call()
        if result == .cannotComplete, ContinuousClock.now - start > .seconds(Double(Self.timeout) / 2) {
            log.notice("\(self.name, privacy: .public) did not answer Accessibility in \(Self.timeout, format: .fixed(precision: 1)) s; asking every 0.5 s")
            if backoff.timedOut(at: start) { startAsking() }
            backedOff.store(true, ordering: .relaxed)
        }
        return result
    }

    private func startAsking() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0) { [weak self] _ in
            self?.assumeIsolated { $0.askAgain() }
        }
        CFRunLoopAddTimer(executor.runLoop, timer, .defaultMode)
        askTimer = timer
    }

    /// Any answer but a timeout lets calls go again (docs/geometry.md).
    private func askAgain() {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(askElement, kAXRoleAttribute as CFString, &value) != .cannotComplete else { return }
        let since = backoff.answered()
        backedOff.store(false, ordering: .relaxed)
        let wasStarted = started
        if wasStarted {
            _ = trackWindows()
            drainWrites()
        } else {
            _ = start()
        }
        guard backoff.settled(started: started) else { return }   // asked again at the next tick
        if let askTimer { CFRunLoopTimerInvalidate(askTimer) }
        askTimer = nil
        if wasStarted { reportAnswering() }
        if let since {
            log.notice("\(self.name, privacy: .public) answers Accessibility again after \((ContinuousClock.now - since).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public)")
        }
    }

    private func send(_ kind: AXReport.Kind) {
        deliver(AXReport(pid: pid, kind: kind, received: .now))
    }

    private nonisolated func deliver(_ report: AXReport) {
        let deliver = self.report
        onMain { deliver(report) }
    }
}
