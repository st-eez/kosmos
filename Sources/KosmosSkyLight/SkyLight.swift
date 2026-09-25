import CKosmos
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "skylight")

/// A window change reported by WindowServer on Kosmos's own connection. Event ids and
/// payloads were measured on macOS 27 (wm-research discovery note, section 2).
public enum WindowServerEvent: Sendable {
    case created(UInt32)
    case destroyed(UInt32)
    case changed(UInt32)   // moved (806), resized (807), ordered in (815) or out (816)
    /// Ordered above or below other windows (808), as when its app raises it.
    case reordered(UInt32)
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
        case 806, 807, 815, 816: guard let w = u32(at: 0) else { return nil }; self = .changed(w)
        case 808: guard let w = u32(at: 0) else { return nil }; self = .reordered(w)
        // A 64 bit Space id, then the window id.
        case 1325, 1326: guard let w = u32(at: 8) else { return nil }; self = .spaceMembership(w)
        case 1327, 1328, 1401: self = .spacesChanged
        case 1508: self = .frontAppChanged
        default: return nil
        }
    }

    /// The window the event names, if any.
    public var window: UInt32? {
        switch self {
        case .created(let id), .destroyed(let id), .changed(let id), .reordered(let id), .spaceMembership(let id): id
        case .spacesChanged, .frontAppChanged: nil
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
    /// The radius WindowServer rounds the window's corners by, 0 for square corners or when
    /// the read left the radii out (`SkyLight.rows`).
    public let cornerRadius: CGFloat
}

public enum SkyLight {
    public static let connection = SLSMainConnectionID()

    /// The first bridged Space operation class this macOS lacks, or nil. Read once; a missing
    /// class logs one fault, and Kosmos then conceals nothing.
    public static let missingBridgedOperation: String? = {
        guard let name = kosmos_bridge_missing() else { return nil }
        let missing = String(cString: name)
        log.fault("\(missing, privacy: .public) is missing from this macOS; hiding stays off")
        return missing
    }()

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

    /// Calls `changed` on the main queue when Secure Input turns on (event 752) or off (753).
    /// The events follow the session's state, whichever process changes it. Measured
    /// September 24, 2026 with throwaway programs: another process turning it on and off sent
    /// 752 and 753; with two overlapping holders, only the first enable and the last release
    /// sent one; and a holder that exited without releasing sent 753 at its exit. Call once.
    @MainActor public static func watchSecureInput(_ changed: @escaping @MainActor () -> Void) {
        secureInputChanged = changed
        for id: UInt32 in [752, 753] {
            let result = SLSRegisterConnectionNotifyProc(connection, { _, _, _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { secureInputChanged?() } }
            }, id, nil)
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

    /// The Spaces the window belongs to, auxiliary Spaces such as the holding Space left out.
    /// Nil when the read fails.
    public static func spaces(of window: UInt32) -> [UInt64]? { kosmos_window_spaces(window) as? [UInt64] }

    /// The windows in the Space. Nil when the read fails, as for a Space that no longer
    /// exists (`kosmos-probe destroyed-space`).
    public static func windows(in space: UInt64) -> [UInt32]? { kosmos_space_windows(space) as? [UInt32] }

    /// Every window on every Space of every display. It can block during a Space
    /// transition, so the inventory calls it off the main thread.
    public static func allWindowIDs() -> [UInt32] {
        let spaces = Displays.current().allSpaces
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let ids = SLSCopyWindowsWithOptionsAndTags(connection, 0, spaces as CFArray, 0x7, &setTags, &clearTags)?
            .takeRetainedValue() as? [UInt32]
        return ids ?? []
    }

    /// Rows for the given windows. Windows that no longer exist are left out. `cornerRadii`
    /// reads each window's corner radius too, which took a read of 2 windows from 14 to
    /// 15 µs at the median (kosmos-probe borders), so only the inventory, whose rows the
    /// borders use, reads them, and Slides' poll, which reads every 100 µs, does not.
    public static func rows(_ ids: [UInt32], cornerRadii: Bool = false) -> [WindowRow] {
        guard !ids.isEmpty, let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count)) else { return [] }
        defer { query.release() }
        guard let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) else { return [] }
        defer { iterator.release() }
        let it = iterator.takeUnretainedValue()
        var rows: [WindowRow] = []
        while SLSWindowIteratorAdvance(it) {
            // The array is the caller's (CKosmos.h).
            let radii = cornerRadii ? SLSWindowIteratorGetCornerRadii(it)?.takeRetainedValue() as? [NSNumber] : nil
            rows.append(WindowRow(id: SLSWindowIteratorGetWindowID(it), pid: SLSWindowIteratorGetPID(it),
                                  parent: SLSWindowIteratorGetParentID(it), level: SLSWindowIteratorGetLevel(it),
                                  orderedIn: SLSWindowIteratorGetAttributes(it) & 0x2 != 0,
                                  frame: SLSWindowIteratorGetBounds(it), cornerRadius: CGFloat(radii?.first?.doubleValue ?? 0)))
        }
        return rows
    }
}

@MainActor private var secureInputChanged: (@MainActor () -> Void)?

private final class EventSink: Sendable {
    private let handler: @MainActor (WindowServerEvent) -> Void

    init(_ handler: @escaping @MainActor (WindowServerEvent) -> Void) { self.handler = handler }

    /// Callbacks arrive on whichever thread read the message, so every event goes through
    /// the main queue to keep one order.
    func send(_ event: WindowServerEvent) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handler(event) } }
    }
}
