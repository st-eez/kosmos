import AppKit
import KosmosCore
import os
import Synchronization

let log = Logger(subsystem: "io.github.st-eez.kosmos.tests", category: "worker")

struct AXFixture {
    var enabled: Bool? = true
    var changes: [Bool] = []
    var refuseRestores = 0
    var setterResult = AXError.notImplemented
    var disableDelay: TimeInterval = 0
    var frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    var frameWriteFlags: [Bool?] = []
}
let fixture = Mutex(AXFixture())

func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                   _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    switch attribute as String {
    case "AXEnhancedUserInterface":
        guard let enabled = fixture.withLock({ $0.enabled }) else { return .attributeUnsupported }
        value.pointee = enabled ? kCFBooleanTrue : kCFBooleanFalse
    case kAXWindowsAttribute: value.pointee = [element] as CFArray
    case kAXPositionAttribute:
        var origin = fixture.withLock { $0.frame.origin }
        value.pointee = AXValueCreate(.cgPoint, &origin)
    case kAXSizeAttribute:
        var size = fixture.withLock { $0.frame.size }
        value.pointee = AXValueCreate(.cgSize, &size)
    case kAXRoleAttribute: value.pointee = kAXApplicationRole as CFString
    default: return .noValue
    }
    return .success
}

func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
    if attribute as String != "AXEnhancedUserInterface" {
        fixture.withLock { state in
            state.frameWriteFlags.append(state.enabled)
            switch attribute as String {
            case kAXPositionAttribute:
                var point = CGPoint.zero
                precondition(AXValueGetValue(value as! AXValue, .cgPoint, &point))
                state.frame.origin = point
            case kAXSizeAttribute:
                var size = CGSize.zero
                precondition(AXValueGetValue(value as! AXValue, .cgSize, &size))
                state.frame.size = size
            default: fatalError("unexpected attribute")
            }
        }
        return .success
    }
    let enabled = value as! Bool
    let (result, delay) = fixture.withLock { state in
        state.changes.append(enabled)
        if enabled, state.refuseRestores > 0 {
            state.refuseRestores -= 1
        } else {
            state.enabled = enabled
        }
        return (state.setterResult, state.disableDelay)
    }
    if !enabled {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    return result
}

func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError {
    window.pointee = 1
    return .success
}

func AXObserverAddNotification(_ observer: AXObserver, _ element: AXUIElement,
                               _ notification: CFString, _ context: UnsafeMutableRawPointer?) -> AXError { .success }

@main
struct Check {
    static let frame = CGRect(x: 10, y: 10, width: 800, height: 600)
    static func write(_ worker: AppWorker) async {
        await worker.setFrames([1: (.frame(frame), frame, false)])
    }

    static func eventually(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "condition did not become true")
    }

    static func worker(_ state: AXFixture) async -> AppWorker {
        fixture.withLock { $0 = state }
        let worker = AppWorker(pid: getpid(), name: "fixture", report: { _ in })
        let started = await worker.start()
        precondition(started, "fixture worker did not start")
        return worker
    }

    static func main() async throws {
        for initial in [true, false, nil] as [Bool?] {
            let w = await worker(AXFixture(enabled: initial))
            await write(w)
            try await Task.sleep(for: .milliseconds(100))
            precondition(fixture.withLock { $0.enabled == initial && $0.changes == (initial == true ? [false, true] : []) })
            let expectedFlag: Bool? = initial == nil ? nil : false
            precondition(fixture.withLock { $0.frame == frame && !$0.frameWriteFlags.isEmpty && $0.frameWriteFlags.allSatisfy { $0 == expectedFlag } })
            await w.stop()
        }
        print("PASS restores an enabled flag despite notImplemented; preserves off and unsupported")

        let retry = await worker(AXFixture(refuseRestores: 1))
        await write(retry)
        try await eventually { fixture.withLock { $0.changes.count >= 3 && $0.enabled == true } }
        precondition(fixture.withLock { $0.changes == [false, true, true] })
        await retry.stop()
        print("PASS retries a refused restore with no frame writes remaining")

        let shutdown = await worker(AXFixture(refuseRestores: 1))
        await write(shutdown)
        try await eventually { fixture.withLock { $0.changes.count == 2 } }
        await shutdown.prepareForShutdown()
        precondition(fixture.withLock { $0.enabled == true && $0.changes == [false, true, true] })
        await write(shutdown)
        try await Task.sleep(for: .milliseconds(600))
        precondition(fixture.withLock { $0.enabled == true && $0.changes == [false, true, true] })
        await shutdown.stop()
        print("PASS shutdown restores during backoff and rejects later writes and timer work")

        let inflight = await worker(AXFixture(disableDelay: 0.2))
        await write(inflight)
        try await eventually { fixture.withLock { $0.changes == [false] } }
        let quitting = Task { await inflight.prepareForShutdown() }
        await write(inflight)
        await quitting.value
        precondition(fixture.withLock { $0.enabled == true })
        let settledChanges = fixture.withLock { $0.changes }
        await write(inflight)
        try await Task.sleep(for: .milliseconds(100))
        precondition(fixture.withLock { $0.enabled == true && $0.changes == settledChanges })
        await inflight.stop()
        print("PASS shutdown waits for an in-flight drain and prevents subsequent suppression")
    }
}
