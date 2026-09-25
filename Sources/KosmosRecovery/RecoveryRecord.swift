import Foundation

/// A process, identified across pid reuse by its start time.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    /// Microseconds since 1970, from the kernel.
    public let start: UInt64

    public init(pid: Int32, start: UInt64) {
        self.pid = pid
        self.start = start
    }

    /// Reads the kernel's process table, which works for processes of other users, such as
    /// WindowServer, where proc_pidinfo does not.
    public static func of(_ pid: Int32) -> ProcessIdentity? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return identity(info)
    }

    public static var current: ProcessIdentity { of(getpid())! }

    /// The WindowServer this session runs on. A record written under another WindowServer
    /// refers to Spaces and windows that no longer exist.
    public static func windowServer() -> ProcessIdentity? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.size + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        let windowServer = processes.prefix(size / MemoryLayout<kinfo_proc>.size).first { info in
            withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "WindowServer"
        }
        return windowServer.map(identity)
    }

    private static func identity(_ info: kinfo_proc) -> ProcessIdentity {
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: info.kp_proc.p_pid,
                               start: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
    }
}

/// What recovery needs to find every window Kosmos concealed (docs/hiding.md;
/// wm-research recovery note, section 4).
public struct RecoveryRecord: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let id: UInt32
        public let owner: ProcessIdentity
        /// The ordinary Space the window was on before its first hide, a fallback
        /// destination for recovery.
        public let originalSpace: UInt64

        public init(id: UInt32, owner: ProcessIdentity, originalSpace: UInt64) {
            self.id = id
            self.owner = owner
            self.originalSpace = originalSpace
        }
    }

    public var windowServer: ProcessIdentity
    public var manager: ProcessIdentity
    /// Spaces Kosmos created. Each is recorded before any window enters it.
    public var spaces: [UInt64]
    /// Windows recorded before their first hide.
    public var windows: [Window]
    /// Spaces the slide trial moves windows in, shown in place at level 1 (docs/hiding.md).
    /// Each is recorded before any window enters it, and every window in one is Kosmos's to
    /// take out.
    public var animationSpaces: [UInt64]

    public init(windowServer: ProcessIdentity, manager: ProcessIdentity, spaces: [UInt64] = [], windows: [Window] = [],
                animationSpaces: [UInt64] = []) {
        self.windowServer = windowServer
        self.manager = manager
        self.spaces = spaces
        self.windows = windows
        self.animationSpaces = animationSpaces
    }

    /// The recorded Space hiding conceals into again after a recovery kept the record: the
    /// newest, while `members`, a read of the recorded Spaces, shows it holding a recorded
    /// window; nil calls for a new one. Recovery sends a destroy only once no recorded window
    /// is left in a recorded Space (Recovery.run), and hiding conceals only into a new Space
    /// or the one returned here. So the Space returned was never sent a destroy, after which
    /// its level, transform and alpha would be unknown.
    public func reusableSpace(members: [UInt64: [UInt32]]) -> UInt64? {
        let recorded = Set(windows.map(\.id))
        guard let newest = spaces.last, members[newest]?.contains(where: recorded.contains) == true else { return nil }
        return newest
    }

    /// The record without the windows that no longer exist, to make room in a full slot.
    /// `alive` is a read of the recorded windows. The windows of `keeping`, the concealed
    /// ones and the ones about to be, stay whatever it says. Nil when it misses a window of
    /// `seen`, which an earlier read found: the read failed, as a failed query reads nothing.
    public func pruned(alive: Set<UInt32>, keeping: Set<UInt32>, seen: [UInt32]) -> RecoveryRecord? {
        guard seen.allSatisfy(alive.contains) else { return nil }
        var pruned = self
        pruned.windows.removeAll { !alive.contains($0.id) && !keeping.contains($0.id) }
        return pruned
    }

    static let magic: UInt32 = 0x4b4f534d   // "KOSM"
    static let version: UInt32 = 1

    /// The decoder's limits; a record beyond them could be written but not read back.
    static let maxSpaces = 64
    static let maxWindows = 4096

    /// Nil when the record is beyond what the decoder accepts.
    func encoded() -> [UInt8]? {
        guard spaces.count <= Self.maxSpaces, windows.count <= Self.maxWindows, animationSpaces.count <= Self.maxSpaces else { return nil }
        var bytes: [UInt8] = []
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        put(Self.magic); put(Self.version)
        put(windowServer.pid); put(windowServer.start)
        put(manager.pid); put(manager.start)
        put(UInt32(spaces.count)); spaces.forEach { put($0) }
        put(UInt32(windows.count))
        for window in windows {
            put(window.id); put(window.owner.pid); put(window.owner.start); put(window.originalSpace)
        }
        // The animation Spaces follow the windows, where a reader that predates them stops, so
        // it still restores every concealed window. With none, the record reads as before.
        if !animationSpaces.isEmpty {
            put(UInt32(animationSpaces.count)); animationSpaces.forEach { put($0) }
        }
        return bytes
    }

    init?(decoding bytes: some Collection<UInt8>) {
        var bytes = bytes[...]
        func take<T: FixedWidthInteger>(_: T.Type = T.self) -> T? {
            let size = MemoryLayout<T>.size
            guard bytes.count >= size else { return nil }
            var value = T.zero
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes.prefix(size)) }
            bytes = bytes.dropFirst(size)
            return T(littleEndian: value)
        }
        guard take(UInt32.self) == Self.magic, take(UInt32.self) == Self.version,
              let wsPid: Int32 = take(), let wsStart: UInt64 = take(),
              let mPid: Int32 = take(), let mStart: UInt64 = take(),
              let spaceCount: UInt32 = take(), spaceCount <= Self.maxSpaces else { return nil }
        var spaces: [UInt64] = []
        for _ in 0..<spaceCount {
            guard let space: UInt64 = take() else { return nil }
            spaces.append(space)
        }
        guard let windowCount: UInt32 = take(), windowCount <= Self.maxWindows else { return nil }
        var windows: [Window] = []
        for _ in 0..<windowCount {
            guard let id: UInt32 = take(), let pid: Int32 = take(), let start: UInt64 = take(),
                  let original: UInt64 = take() else { return nil }
            windows.append(Window(id: id, owner: ProcessIdentity(pid: pid, start: start), originalSpace: original))
        }
        var animationSpaces: [UInt64] = []
        if !bytes.isEmpty {
            guard let count: UInt32 = take(), count <= Self.maxSpaces else { return nil }
            for _ in 0..<count {
                guard let space: UInt64 = take() else { return nil }
                animationSpaces.append(space)
            }
        }
        self.init(windowServer: ProcessIdentity(pid: wsPid, start: wsStart),
                  manager: ProcessIdentity(pid: mPid, start: mStart), spaces: spaces, windows: windows,
                  animationSpaces: animationSpaces)
    }
}
