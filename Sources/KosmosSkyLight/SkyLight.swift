import CKosmos
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "io.github.st-eez.kosmos", category: "skylight")

/// Ids and payloads measured on macOS 27 (docs/inventory.md).
public enum WindowServerEvent: Sendable {
    case created(UInt32)
    case destroyed(UInt32)
    case changed(UInt32)
    /// As when its app raises it.
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

    public var window: UInt32? {
        switch self {
        case .created(let id), .destroyed(let id), .changed(let id), .reordered(let id), .spaceMembership(let id): id
        case .spacesChanged, .frontAppChanged: nil
        }
    }
}

public struct WindowRow: Sendable, Equatable {
    public let id: UInt32
    public let pid: pid_t
    public let parent: UInt32
    public let level: Int32
    public let orderedIn: Bool
    public let frame: CGRect
    /// 0 for square corners, or when the read left the radii out.
    public let cornerRadius: CGFloat
    /// The smallest size WindowServer holds the window to, zero on an axis the app leaves
    /// free and when the read left it out (docs/geometry.md).
    public let minimum: CGSize
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

    /// Calls `changed` on the main queue when Secure Input turns on or off, whichever process
    /// changes it (docs/hotkeys.md). Call once.
    @MainActor public static func watchSecureInput(_ changed: @escaping @MainActor () -> Void) {
        secureInputChanged = changed
        for id: UInt32 in [752, 753] {
            let result = SLSRegisterConnectionNotifyProc(connection, { _, _, _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { secureInputChanged?() } }
            }, id, nil)
            if result != .success { log.error("SkyLight event \(id) not registered: \(result.rawValue)") }
        }
    }

    /// WindowServer keeps only the latest list, so each call names every window to watch.
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

    /// It can block during a Space transition, so call it off the main thread.
    public static func allWindowIDs() -> [UInt32] {
        let spaces = Displays.current().allSpaces
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let ids = SLSCopyWindowsWithOptionsAndTags(connection, 0, spaces as CFArray, 0x7, &setTags, &clearTags)?
            .takeRetainedValue() as? [UInt32]
        return ids ?? []
    }

    /// Windows that no longer exist are left out, and a failed query reads as every window
    /// gone. The radii add about 1 µs to a read of 2 windows, and the minimums add 8 to 10 µs to
    /// a read of 50, so only the inventory reads them (docs/borders.md, docs/geometry.md).
    public static func rows(_ ids: [UInt32], cornerRadii: Bool = false, minimums: Bool = false) -> [WindowRow] {
        readRows(ids, cornerRadii: cornerRadii, minimums: minimums) ?? []
    }

    /// Nil when the query fails, for a caller that must not take that for every window gone
    /// (docs/hiding.md).
    public static func readRows(_ ids: [UInt32], cornerRadii: Bool = false, minimums: Bool = false) -> [WindowRow]? {
        guard !ids.isEmpty else { return [] }
        guard let query = SLSWindowQueryWindows(connection, ids as CFArray, Int32(ids.count)) else { return nil }
        defer { query.release() }
        guard let iterator = SLSWindowQueryResultCopyWindows(query.takeUnretainedValue()) else { return nil }
        defer { iterator.release() }
        let it = iterator.takeUnretainedValue()
        var rows: [WindowRow] = []
        while SLSWindowIteratorAdvance(it) {
            // The array is the caller's (CKosmos.h).
            let radii = cornerRadii ? SLSWindowIteratorGetCornerRadii(it)?.takeRetainedValue() as? [NSNumber] : nil
            let parent = SLSWindowIteratorGetParentID(it), level = SLSWindowIteratorGetLevel(it)
            rows.append(WindowRow(id: SLSWindowIteratorGetWindowID(it), pid: SLSWindowIteratorGetPID(it),
                                  parent: parent, level: level, orderedIn: SLSWindowIteratorGetAttributes(it) & 0x2 != 0,
                                  frame: SLSWindowIteratorGetBounds(it), cornerRadius: CGFloat(radii?.first?.doubleValue ?? 0),
                                  minimum: minimums && parent == 0 && level == 0 ? minimum(it) : .zero))
        }
        return rows
    }

    /// With no constraint in the row at all, the one the window's package keeps, as rift reads
    /// it (`constraints()` in src/sys/window_server.rs). A package read takes 7 µs, so only a
    /// window Kosmos can manage, at level 0 with no parent, gets one.
    private static func minimum(_ iterator: CFTypeRef) -> CGSize {
        var minimum = CGSize.zero, maximum = CGSize.zero, current = CGSize.zero
        _ = SLSWindowIteratorGetConstraints(iterator, &minimum, &maximum, &current)
        if minimum == .zero, maximum == .zero {
            _ = SLSPackagesGetWindowConstraints(connection, SLSWindowIteratorGetWindowID(iterator), &minimum, &maximum, &current)
        }
        return minimum
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
