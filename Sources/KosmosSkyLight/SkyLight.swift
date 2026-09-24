import CSkyLight
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "skylight")

/// A window change reported by WindowServer on Kosmos's own connection. Event ids and
/// payloads were measured on macOS 27 (wm-research discovery note, section 2).
public enum WindowServerEvent: Sendable {
    case created(UInt32)
    case destroyed(UInt32)
    case changed(UInt32)   // ordered in or out, moved, resized or reordered
    case spaceMembership(UInt32)
    case spacesChanged     // a Space was created or destroyed, or the active Space changed
    case frontAppChanged

    public static let ids: [UInt32] = [804, 806, 807, 808, 811, 815, 816, 1325, 1326, 1327, 1328, 1401, 1508]

    public init?(id: UInt32, payload: UnsafeRawBufferPointer) {
        func u32(at offset: Int) -> UInt32? {
            payload.count >= offset + 4 ? payload.loadUnaligned(fromByteOffset: offset, as: UInt32.self) : nil
        }
        switch id {
        case 811: guard let w = u32(at: 0) else { return nil }; self = .created(w)
        case 804: guard let w = u32(at: 0) else { return nil }; self = .destroyed(w)
        case 806, 807, 808, 815, 816: guard let w = u32(at: 0) else { return nil }; self = .changed(w)
        // A 64 bit Space id, then the window id.
        case 1325, 1326: guard let w = u32(at: 8) else { return nil }; self = .spaceMembership(w)
        case 1327, 1328, 1401: self = .spacesChanged
        case 1508: self = .frontAppChanged
        default: return nil
        }
    }
}

/// One window as WindowServer describes it.
public struct WindowRow: Sendable, Equatable {
    public let id: UInt32
    public let pid: pid_t
    public let parent: UInt32
    public let level: Int32
    public let orderedIn: Bool
    public let frame: CGRect
}

public enum SkyLight {
    public static let connection = SLSMainConnectionID()

    /// Delivers every event on the main queue in the order WindowServer sent it. Call once.
    public static func subscribe(_ handler: @escaping @MainActor (WindowServerEvent) -> Void) {
        let sink = Unmanaged.passRetained(EventSink(handler)).toOpaque()   // lives for the process
        for id in WindowServerEvent.ids {
            let result = SLSRegisterConnectionNotifyProc(connection, { id, data, length, context, _ in
                let payload = UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : length)
                guard let context, let event = WindowServerEvent(id: id, payload: payload) else { return }
                Unmanaged<EventSink>.fromOpaque(context).takeUnretainedValue().send(event)
            }, id, sink)
            if result != .success { log.error("SkyLight event \(id) not registered: \(result.rawValue)") }
        }
    }

    /// Replaces the list of windows whose per-window events (804, 806 to 808, 815, 816) are
    /// delivered. WindowServer keeps only the latest list.
    public static func watch(_ windows: [UInt32]) {
        var windows = windows
        let result = SLSRequestNotificationsForWindows(connection, &windows, Int32(windows.count))
        if result != .success { log.error("watch list of \(windows.count) windows rejected: \(result.rawValue)") }
    }

    /// Every window on every Space of every display. It can block during a Space
    /// transition, so the inventory calls it off the main thread.
    public static func allWindowIDs() -> [UInt32] {
        let displays = SLSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        let spaces = displays.flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? UInt64 } }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let ids = SLSCopyWindowsWithOptionsAndTags(connection, 0, spaces as CFArray, 0x7, &setTags, &clearTags)?
            .takeRetainedValue() as? [UInt32]
        return ids ?? []
    }

    /// Rows for the given windows. Windows that no longer exist are left out.
    public static func rows(_ ids: [UInt32]) -> [WindowRow] {
        guard !ids.isEmpty, let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count)) else { return [] }
        defer { query.release() }
        guard let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) else { return [] }
        defer { iterator.release() }
        let it = iterator.takeUnretainedValue()
        var rows: [WindowRow] = []
        while SLSWindowIteratorAdvance(it) {
            rows.append(WindowRow(id: SLSWindowIteratorGetWindowID(it), pid: SLSWindowIteratorGetPID(it),
                                  parent: SLSWindowIteratorGetParentID(it), level: SLSWindowIteratorGetLevel(it),
                                  orderedIn: SLSWindowIteratorGetAttributes(it) & 0x2 != 0,
                                  frame: SLSWindowIteratorGetBounds(it)))
        }
        return rows
    }
}

private final class EventSink: Sendable {
    private let handler: @MainActor (WindowServerEvent) -> Void

    init(_ handler: @escaping @MainActor (WindowServerEvent) -> Void) { self.handler = handler }

    /// Callbacks arrive on whichever thread read the message, so every event goes through
    /// the main queue to keep one order.
    func send(_ event: WindowServerEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handler(event) } }
    }
}
