import AppKit
import KosmosCore
import Synchronization
import os

let inputLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "input")

/// The user's key downs and clicks, with the process each went to, from a listen-only tap at
/// the annotated session location, where WindowServer fills in each event's source and target
/// processes, and his key downs from one at the session location, which also sees a hotkey's
/// key (docs/focus.md). Made only with Input Monitoring, so it never asks for it.
final class InputTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.input")
    /// Set once in `init`.
    private nonisolated(unsafe) var annotated, session: CFMachPort?
    private let input = Mutex(OwnInput())
    private let heard = Atomic<Bool>(false)

    init?() {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        annotated = tap(at: .cgAnnotatedSessionEventTap, for: types) { _, type, event, refcon in
            Unmanaged<InputTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        session = tap(at: .cgSessionEventTap, for: [.keyDown]) { _, type, event, refcon in
            Unmanaged<InputTap>.fromOpaque(refcon!).takeUnretainedValue().handleSession(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard annotated != nil, session != nil else {
            for port in [annotated, session].compactMap({ $0 }) { CFMachPortInvalidate(port) }
            inputLog.error("input tap not created: every window change counts as the user's")
            executor.stop()
            return nil
        }
        executor.perform { [self] in
            for port in [self.annotated, self.session].compactMap({ $0 }) { CGEvent.tapEnable(tap: port, enable: true) }
        }
        inputLog.notice("input tap created")
    }

    private func tap(at location: CGEventTapLocation, for types: [CGEventType],
                     _ callback: @convention(c) (CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?)
        -> CFMachPort? {
        guard let port = CGEvent.tapCreate(
            tap: location, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue },
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        return port
    }

    /// Why a change `app` made at `stamp` is the user's, or nil when no input of his could have
    /// (OwnInput). The app's bundle and each target's policy are read on the main actor.
    @MainActor
    func cause(of app: pid_t, at stamp: ContinuousClock.Instant) -> OwnInput.Cause? {
        let now = ContinuousClock.now
        let snapshot = input.withLock { $0 }
        let running = NSRunningApplication(processIdentifier: app)
        let launched = running?.launchDate.map { now - .seconds(-$0.timeIntervalSinceNow) }
        let bundle = running?.bundleURL?.path
        return snapshot.cause(at: stamp, launched: launched, listening: CGPreflightListenEventAccess(), now: now) { target in
            if target == app { return .app }
            if let bundle, processPath(target)?.hasPrefix(bundle + "/") == true { return .app }
            return NSRunningApplication(processIdentifier: target)?.activationPolicy == .regular ? .otherApp : .notRegular
        }
    }

    /// Live, where HID's event state comes in 500 ms batches on macOS 27.2.1
    /// (docs/focus-follows-mouse.md).
    func secondsSinceKey() -> Double? {
        guard CGPreflightListenEventAccess() else { return nil }
        return input.withLock { $0.lastKey }.map { (ContinuousClock.now - $0) / .seconds(1) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let stamp = ContinuousClock.now
        if type != .tapDisabledByTimeout, type != .tapDisabledByUserInput, !heard.exchange(true, ordering: .relaxed) {
            inputLog.notice("input tap receiving events")
        }
        switch type {
        case .keyDown:
            input.withLock {
                $0.heardKey(from: event.pid(.eventSourceUnixProcessID), target: event.pid(.eventTargetUnixProcessID), event: event.timestamp, at: stamp)
            }
        case .flagsChanged:
            input.withLock { $0.heardModifiers(from: event.pid(.eventSourceUnixProcessID), target: event.pid(.eventTargetUnixProcessID), at: stamp) }
        case .leftMouseDown, .rightMouseDown:
            input.withLock { $0.heardClick(from: event.pid(.eventSourceUnixProcessID), target: event.pid(.eventTargetUnixProcessID), at: stamp) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            turnOnAgain(annotated, type)
        default:
            break
        }
    }

    private func handleSession(_ type: CGEventType, _ event: CGEvent) {
        let stamp = ContinuousClock.now
        switch type {
        case .keyDown:
            input.withLock { $0.heardSessionKey(from: event.pid(.eventSourceUnixProcessID), event: event.timestamp, at: stamp) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            turnOnAgain(session, type)
        default:
            break
        }
    }

    private func turnOnAgain(_ port: CFMachPort?, _ type: CGEventType) {
        inputLog.notice("input tap turned off by WindowServer (\(type.rawValue)); turning it on again")
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

extension CGEvent {
    func pid(_ field: CGEventField) -> Int32 { Int32(truncatingIfNeeded: getIntegerValueField(field)) }
}

func processName(_ pid: pid_t) -> String {
    var name = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "?" }
    return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func processPath(_ pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
