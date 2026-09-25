import AppKit
import CKosmos
import KosmosCore
import Synchronization

/// What an app's worker tells the main actor. Each report is stamped on receipt, so the
/// main actor can order it against commands (docs/focus.md).
struct AXReport: Sendable {
    enum Kind: Sendable {
        case windowCreated(UInt32)
        case windowDestroyed(UInt32)
        /// The key window: the focused window of the app that is front.
        case focusedWindowChanged(UInt32?)
        /// The focused window of an app that is not front when it reports it, as after
        /// AXRaise in it. It is no key window report, but it can be Kosmos's echo.
        case backgroundFocus(UInt32?)
        case minimized(UInt32, Bool)
        /// Frames read back after writes, with the target each write aimed for.
        case framesApplied([(id: UInt32, target: CGRect, readBack: CGRect)])
        /// Windows whose frame writes the worker dropped, as it knows no element for them.
        case framesDropped([UInt32])
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
    var minimized: Bool
}

/// Owns one app's Accessibility elements and observer on the app's own thread. It never
/// touches the model: it reports to the main actor and answers reads.
///
/// An app that lets a call wait out the messaging timeout is backed off: the worker makes no
/// call to it, keeps only the newest frame target of each window, and asks it for its role
/// with a 50 ms timeout every 0.5 s. When it answers, the worker writes the held frames and
/// reports `answering` (docs/geometry.md).
actor AppWorker {
    /// Every call waits this long at most, set system wide in `Apps.start`. A call to a hung
    /// app returns kAXErrorCannotComplete 5 ms after its timeout; with none set, macOS 27
    /// waits 1.5 s (`kosmos-probe ax-timeout`).
    static let timeout: Float = 1.0
    /// How long the worker waits for the app to perform a raise. A raise it stopped waiting
    /// for still lands when the app gets to it, and can key a window after a newer command
    /// (tla/README.md, change 19, `split-user-timeout`). One that outlasts this counts as
    /// made, so its echo is still recognized, and its app is backed off. No measurement chose
    /// the 5 s.
    static let raiseTimeout: Float = 5.0

    let pid: pid_t
    private let name: String
    private let executor: RunLoopExecutor
    /// Runs the app's AX observer, apart from the worker's calls into the app, so a focus
    /// notification is stamped and checked against the front process in its callback, which
    /// never waits behind the worker's calls (tla/README.md, change 19). Checked behind a
    /// busy worker, a click inside the front app that raced Kosmos's activation of another app
    /// was dropped (`split-user-latenote`). The callback still runs some time after the app
    /// sends the notification, and Kosmos can key or hide windows in between (change 20).
    private let observerLoop: RunLoopExecutor
    private let report: @MainActor (AXReport) -> Void
    private let app: AXUIElement
    private var observer: AXObserver?
    private var started = false
    /// Why the last start failed, for the log after the launch retries.
    private(set) var startFailure = "no answer"
    private var elements: [UInt32: AXUIElement] = [:]
    /// Writes waiting for the next drain; a newer target replaces an older one.
    private var queuedWrites: [UInt32: (write: FrameWrite, target: CGRect)] = [:]
    private var drainScheduled = false
    private var backoff = AXBackoff<ContinuousClock.Instant>()
    /// `backoff.backedOff` for the main actor, which slides no window of an app that does not
    /// answer (Controller.motions).
    private nonisolated let backedOff = Atomic(false)
    /// Runs while `backoff` is asking.
    private var probe: CFRunLoopTimer?
    private let probeElement: AXUIElement

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    init(pid: pid_t, name: String, report: @escaping @MainActor (AXReport) -> Void) {
        self.pid = pid
        self.name = name
        self.report = report
        executor = RunLoopExecutor(name: "kosmos.ax.\(name)")
        observerLoop = RunLoopExecutor(name: "kosmos.ax.\(name).observer")
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
        // A call that timed out above leaves the worker to the probe.
        guard trackWindows(), !backoff.backedOff else {
            startFailure = backoff.backedOff ? "timed out" : "window list not read"
            return false
        }
        started = true
        reportAnswering()
        return true
    }

    /// Reports `answering`, then the app's focused window (docs/geometry.md).
    private func reportAnswering() {
        send(.answering)
        guard let window = focusedWindow() else { return }
        send(kosmos_front_pid() == pid ? .focusedWindowChanged(window) : .backgroundFocus(window))
    }

    /// Tracks every window the app lists. False when the app did not answer.
    private func trackWindows() -> Bool {
        let windows: CFTypeRef?
        do { windows = try copy(app, kAXWindowsAttribute) } catch { return false }
        for window in windows as? [AXUIElement] ?? [] { track(window) }
        return true
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(observerLoop.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        if let probe { CFRunLoopTimerInvalidate(probe) }
        observer = nil
        probe = nil
        elements = [:]
        observerLoop.stop()
        executor.stop()
    }

    /// The facts of each window the worker knows. A window missing is unknown to it, or its
    /// app did not answer; the caller keeps what it knew, since an unanswered read never makes
    /// a window unmanaged. Windows the app did not list when the worker started, nor report
    /// created, are looked for in its list again, once for all of them, as for an app
    /// launched hidden once it unhides. Before the worker starts it knows no window, so a
    /// window is admitted only after its app's focused window is reported (docs/geometry.md).
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

    var windowIDs: [UInt32] { Array(elements.keys) }

    /// Whether calls go to the app: it is not backed off.
    nonisolated var answers: Bool { !backedOff.load(ordering: .relaxed) }

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

    /// The worker's part of a private focus request for a window, as one job the focus queue
    /// waits on at most 30 ms (FocusQueue.swift). Its steps are the split model's `WorkerStart`,
    /// `WorkerRead` and `WorkerRaise` (KosmosCore's KeyRequest), and it acts only for the front
    /// app, where the raise keys the window. The generation is checked at each step. Just
    /// before AXRaise the worker records the echo through `performing`, which reaches the
    /// main actor before any report of the raise. A read with no answer stops the request,
    /// and a raise that cannot land forgets its record through `dropped`.
    nonisolated func focusPrivately(_ id: UInt32, isCurrent: @escaping @Sendable () -> Bool, request: KeyRequest,
                                    performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                    dropped: @escaping @Sendable (ContinuousClock.Instant) -> Void,
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
                if !worker.raiseWindow(id) { dropped(stamp) }
            }
        }
    }

    /// The raise after the queue's key record for this background app (`WorkerPost`,
    /// KosmosCore's KeyRequest), which brings the keyed window to the top of its app. The key
    /// record alone put it on top 0 times in 20, the key record then AXRaise 20 times in 20
    /// (`kosmos-probe keying`). The echo is recorded through `performing` just before the
    /// raise, as the raise keys the window again if the user keyed another window of the app
    /// first. Once the raise has returned and the worker has read the app's focused window,
    /// `raised` tells the main actor to forget the record if no report used it
    /// (tla/README.md, change 23).
    ///
    /// The ceiling: the raise's report hops to the main actor from the observer's thread, and
    /// `raised` from the worker's, so the report can arrive after its record is forgotten and
    /// read as the user's choice of the window. The spec has the app's callbacks for the raise
    /// run before the worker's read, as they run before its activation read. The upgrade is
    /// to forget the record only once the observer has handled the notifications the app sent
    /// before answering the read (docs/focus.md).
    nonisolated func raiseAfterKeyRecord(_ id: UInt32, performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                                         raised: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        executor.perform {
            self.assumeIsolated { worker in
                let focused = worker.focusedWindow()
                let front = kosmos_front_pid() == worker.pid
                guard worker.elements[id] != nil,
                      KeyRequest.workerPostRaises(appIsFront: front, focused: focused, target: id) else {
                    // Logged to tell a read that came before the app handled the key record
                    // from the user moving on (docs/focus.md).
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

    /// Reads the app's focused window for the focus queue, which waits for it at most 30 ms.
    /// `done` gets nil when the app did not answer.
    nonisolated func readFocusedWindow(_ done: @escaping @Sendable (UInt32??) -> Void) {
        executor.perform { self.assumeIsolated { done($0.focusedWindow()) } }
    }

    /// The public focus path for a window, for when the private one is off or its call fails
    /// (docs/focus.md), as one job: skips a target that is key already, records the
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
                if NSRunningApplication(processIdentifier: worker.pid)?.activate(options: []) != true { dropped(stamp) }
            }
        }
    }

    private func logUnanswered(_ id: UInt32) {
        log.notice("\(self.name, privacy: .public) did not answer the focused window read; focus on \(id) stops")
    }

    /// Raises the window and waits for the app to perform it, for up to `raiseTimeout`.
    /// Returns false when no raise can land: the app refused it or failed at once, or the
    /// worker made no call. A raise that timed out can still land and counts as made.
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
            // A write or read the app did not answer waits, with the ones after it, for the
            // app to answer again. One whose read failed otherwise waits for the app's next
            // frame write.
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
            let spent = ContinuousClock.now - start
            let ms = Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15
            log.info("\(id) written, AX time \(ms, format: .fixed(precision: 2)) ms")
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

    /// An observer callback, on the observer's thread. A focus change is stamped and checked
    /// against the front process here, before anything that can wait on the app: only the
    /// front app's focused window is the key window (tla/Kosmos.tla, Observe). Its window
    /// id is asked of the app on this thread, which a slow app delays only for its own
    /// notifications. Everything else goes to the worker, in order.
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

    /// Caches a window element under its WindowServer id and observes it. Before the
    /// observer exists nothing is cached, so `start` still observes the window. Nor is a
    /// window cached when a registration timed out: the windows tracked again after the app
    /// answers, in `askAgain`, register it then, so its minimize is not missed for good.
    @discardableResult
    private func track(_ element: AXUIElement) -> UInt32? {
        // A cached element needs no round trip, so listing the windows again costs one call.
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
            backedOff.store(true, ordering: .relaxed)
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
    /// the worker reports `answering`, as `start` does.
    private func askAgain() {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(probeElement, kAXRoleAttribute as CFString, &value) != .cannotComplete else { return }
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
        if let probe { CFRunLoopTimerInvalidate(probe) }
        probe = nil
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
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(report) } }
    }
}
