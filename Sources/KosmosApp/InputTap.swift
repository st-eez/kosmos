import AppKit
import KosmosCore
import Synchronization
import os

let inputLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "input")

/// The user's key downs and clicks, with the process each went to, from a listen-only tap at
/// the annotated session location, where WindowServer fills in each event's source and target
/// processes (docs/focus.md). Made only with Input Monitoring, so it never asks for it.
final class InputTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.input")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let input = Mutex(OwnInput())
    private let heard = Atomic<Bool>(false)

    init?() {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, refcon in
                Unmanaged<InputTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port else {
            inputLog.error("input tap not created: every window change counts as the user's")
            executor.stop()
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        executor.perform { [self] in
            if let port = self.port { CGEvent.tapEnable(tap: port, enable: true) }
        }
        inputLog.notice("input tap created")
    }

    /// Why a change `app` made at `stamp` is the user's, or nil when no input of his could have
    /// (OwnInput). The app's bundle and each target's policy are read on the main actor.
    @MainActor
    func cause(of app: pid_t, at stamp: ContinuousClock.Instant) -> OwnInput.Cause? {
        let now = ContinuousClock.now
        let lastKey = now - .seconds(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown))
        let count = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        let snapshot = self.input.withLock { input in
            input.noteUnseenKeys(hidKeys: count, lastKeyAt: lastKey)
            return input
        }
        let running = NSRunningApplication(processIdentifier: app)
        let launched = running?.launchDate.map { now - .seconds(-$0.timeIntervalSinceNow) }
        let bundle = running?.bundleURL?.path
        return snapshot.cause(at: stamp, launched: launched, listening: CGPreflightListenEventAccess()) { target in
            if target == app { return .app }
            if let bundle, processPath(target)?.hasPrefix(bundle + "/") == true { return .app }
            return NSRunningApplication(processIdentifier: target)?.activationPolicy == .regular ? .otherApp : .notRegular
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let stamp = ContinuousClock.now
        func pid(_ field: CGEventField) -> Int32 { Int32(truncatingIfNeeded: event.getIntegerValueField(field)) }
        if type != .tapDisabledByTimeout, type != .tapDisabledByUserInput, !heard.exchange(true, ordering: .relaxed) {
            inputLog.notice("input tap receiving events")
        }
        switch type {
        case .keyDown:
            let count = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
            input.withLock {
                $0.heardKey(from: pid(.eventSourceUnixProcessID), target: pid(.eventTargetUnixProcessID), hidKeys: count, at: stamp)
            }
        case .flagsChanged:
            let count = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
            let lastKey = stamp - .seconds(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown))
            input.withLock {
                $0.heardModifiers(from: pid(.eventSourceUnixProcessID), target: pid(.eventTargetUnixProcessID), hidKeys: count,
                                  lastKeyAt: lastKey, at: stamp)
            }
        case .leftMouseDown, .rightMouseDown:
            input.withLock { $0.heardClick(from: pid(.eventSourceUnixProcessID), target: pid(.eventTargetUnixProcessID), at: stamp) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            inputLog.notice("input tap turned off by WindowServer (\(type.rawValue)); turning it on again")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            break
        }
    }
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
