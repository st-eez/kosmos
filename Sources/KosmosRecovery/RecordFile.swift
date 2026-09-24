import Foundation

/// The recovery record in an 8 KiB file mapped shared, with two 4 KiB slots. A publish fills
/// the older slot and stores its generation last; a reader takes the valid slot with the
/// higher generation. Nothing is synced to disk: the record only has to outlive Kosmos, not
/// the machine, and the page cache keeps it when the process dies (wm-research recovery
/// note, section 4).
public final class RecordFile {
    static let slotSize = 4096
    /// generation (8), CRC32 of length and payload (4), payload length (4).
    static let headerSize = 16
    public static var capacity: Int { slotSize - headerSize }

    public let url: URL
    private let memory: UnsafeMutableRawPointer

    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(2 * Self.slotSize)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let mapped = mmap(nil, 2 * Self.slotSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        memory = mapped
    }

    deinit { munmap(memory, 2 * Self.slotSize) }

    /// The newest valid record, or nil when there is none.
    public func read() -> RecoveryRecord? {
        let slots = (0..<2).compactMap { slot(at: $0) }
        guard let newest = slots.max(by: { $0.generation < $1.generation }) else { return nil }
        return RecoveryRecord(decoding: newest.payload)
    }

    /// Publishes a record. Returns false when it does not fit in a slot.
    @discardableResult
    public func publish(_ record: RecoveryRecord) -> Bool {
        guard let payload = record.encoded(), payload.count <= Self.capacity else { return false }
        let current = (0..<2).compactMap { index in slot(at: index).map { (index, $0.generation) } }
        let newest = current.max { $0.1 < $1.1 }
        let target = newest.map { 1 - $0.0 } ?? 0
        let generation = (newest?.1 ?? 0) + 1

        let base = memory + target * Self.slotSize
        base.storeBytes(of: UInt64(0), as: UInt64.self)   // invalid while it is written
        var length = UInt32(payload.count).littleEndian
        payload.withUnsafeBytes { (base + Self.headerSize).copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        (base + 12).storeBytes(of: length, as: UInt32.self)
        var crc = CRC32()
        withUnsafeBytes(of: &length) { crc.update($0) }
        crc.update(payload)
        (base + 8).storeBytes(of: crc.value.littleEndian, as: UInt32.self)
        base.storeBytes(of: generation.littleEndian, as: UInt64.self)
        return true
    }

    /// Clears both slots.
    public func clear() {
        memset(memory, 0, 2 * Self.slotSize)
    }

    private func slot(at index: Int) -> (generation: UInt64, payload: [UInt8])? {
        let base = memory + index * Self.slotSize
        let generation = UInt64(littleEndian: base.loadUnaligned(as: UInt64.self))
        let storedCRC = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let rawLength = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let length = Int(UInt32(littleEndian: rawLength))
        guard generation != 0, length <= Self.capacity else { return nil }
        let payload = [UInt8](UnsafeRawBufferPointer(start: base + Self.headerSize, count: length))
        var crc = CRC32()
        withUnsafeBytes(of: rawLength) { crc.update($0) }
        crc.update(payload)
        guard crc.value == storedCRC else { return nil }
        return (generation, payload)
    }
}

/// CRC-32 (IEEE), enough to reject a slot torn by a crash mid-publish.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF
    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8) }
    }

    mutating func update(_ buffer: UnsafeRawBufferPointer) { update(buffer.lazy.map { $0 }) }
}
