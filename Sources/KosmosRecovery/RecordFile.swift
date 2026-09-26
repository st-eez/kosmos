import Foundation
import zlib

/// Two slots in a file mapped shared, never synced, since the page cache keeps the record when
/// the process dies (docs/hiding.md).
public final class RecordFile {
    static let slotSize = 4096
    /// generation (8), CRC32 of length and payload (4), payload length (4).
    static let headerSize = 16
    public static var capacity: Int { slotSize - headerSize }

    private let memory: UnsafeMutableRawPointer

    public init(url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(2 * Self.slotSize)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let mapped = mmap(nil, 2 * Self.slotSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        memory = mapped
    }

    deinit { munmap(memory, 2 * Self.slotSize) }

    public func read() -> RecoveryRecord? { Self.newest(in: memory) }

    /// Reads without opening the file for writing, as `kosmos-probe holding` reads a running
    /// Kosmos's record.
    public static func peek(_ url: URL) -> RecoveryRecord? {
        guard let data = try? Data(contentsOf: url), data.count == 2 * slotSize else { return nil }
        return data.withUnsafeBytes { newest(in: $0.baseAddress!) }
    }

    private static func newest(in memory: UnsafeRawPointer) -> RecoveryRecord? {
        let slots = (0..<2).compactMap { slot(in: memory, at: $0) }
        guard let newest = slots.max(by: { $0.generation < $1.generation }) else { return nil }
        return RecoveryRecord(decoding: newest.payload)
    }

    /// False when the record does not fit in a slot.
    @discardableResult
    public func publish(_ record: RecoveryRecord) -> Bool {
        guard let payload = record.encoded(), payload.count <= Self.capacity else { return false }
        let current = (0..<2).compactMap { index in Self.slot(in: memory, at: index).map { (index, $0.generation) } }
        let newest = current.max { $0.1 < $1.1 }
        let target = newest.map { 1 - $0.0 } ?? 0
        let generation = (newest?.1 ?? 0) + 1

        let base = memory + target * Self.slotSize
        base.storeBytes(of: UInt64(0), as: UInt64.self)   // invalid while it is written
        var length = UInt32(payload.count).littleEndian
        payload.withUnsafeBytes { (base + Self.headerSize).copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        (base + 12).storeBytes(of: length, as: UInt32.self)
        let crc = payload.withUnsafeBytes { payload in withUnsafeBytes(of: &length) { Self.crc32($0, payload) } }
        (base + 8).storeBytes(of: crc.littleEndian, as: UInt32.self)
        base.storeBytes(of: generation.littleEndian, as: UInt64.self)
        return true
    }

    public func clear() {
        memset(memory, 0, 2 * Self.slotSize)
    }

    private static func slot(in memory: UnsafeRawPointer, at index: Int) -> (generation: UInt64, payload: [UInt8])? {
        let base = memory + index * slotSize
        let generation = UInt64(littleEndian: base.loadUnaligned(as: UInt64.self))
        let storedCRC = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let rawLength = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let length = Int(UInt32(littleEndian: rawLength))
        guard generation != 0, length <= capacity else { return nil }
        let payload = [UInt8](UnsafeRawBufferPointer(start: base + headerSize, count: length))
        let crc = payload.withUnsafeBytes { payload in withUnsafeBytes(of: rawLength) { crc32($0, payload) } }
        guard crc == storedCRC else { return nil }
        return (generation, payload)
    }

    /// CRC-32 (IEEE) of the buffers in turn, enough to reject a slot torn by a crash mid-publish.
    static func crc32(_ buffers: UnsafeRawBufferPointer...) -> UInt32 {
        UInt32(buffers.reduce(uLong(0)) { crc, bytes in
            guard let base = bytes.baseAddress else { return crc }
            return zlib.crc32(crc, base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count))
        })
    }
}
