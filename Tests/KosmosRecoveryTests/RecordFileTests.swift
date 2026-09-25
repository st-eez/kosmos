import Foundation
import Testing
@testable import KosmosRecovery

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kosmos-record-\(UUID().uuidString)")
}

private let identity = ProcessIdentity(pid: 42, start: 1_790_000_000_000_000)

private func record(spaces: [UInt64], windows: Int = 0) -> RecoveryRecord {
    RecoveryRecord(windowServer: identity, manager: ProcessIdentity(pid: 7, start: 9), spaces: spaces,
                   windows: (0..<windows).map { .init(id: UInt32($0), owner: identity, originalSpace: 3) })
}

@Test func crc32MatchesTheStandardCheckValue() {
    var crc = CRC32()
    crc.update(Array("123456789".utf8))
    #expect(crc.value == 0xCBF4_3926)
}

@Test func emptyFileHasNoRecord() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try RecordFile(url: url).read() == nil)
}

@Test func newestPublishWinsAndSurvivesReopening() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    file.publish(record(spaces: [1]))
    file.publish(record(spaces: [1, 2], windows: 3))
    file.publish(record(spaces: [5]))
    #expect(try RecordFile(url: url).read() == record(spaces: [5]))
    #expect(RecordFile.peek(url) == record(spaces: [5]))
    #expect(RecordFile.peek(temporaryFile()) == nil)
}

@Test func tornSlotFallsBackToTheOlderRecord() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    file.publish(record(spaces: [1]))            // slot 0
    file.publish(record(spaces: [2], windows: 2)) // slot 1
    // Corrupt one payload byte of slot 1, as a crash in the middle of a publish would.
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: UInt64(RecordFile.slotSize + RecordFile.headerSize + 20))
    try handle.write(contentsOf: Data([0xAB]))
    try handle.close()
    #expect(try RecordFile(url: url).read() == record(spaces: [1]))
}

@Test func recordThatDoesNotFitIsRefused() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    #expect(file.publish(record(spaces: [1], windows: 150)))
    #expect(!file.publish(record(spaces: [1], windows: 200)))
    #expect(file.read()?.windows.count == 150)
}

@Test func clearRemovesTheRecord() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    file.publish(record(spaces: [1]))
    file.clear()
    #expect(file.read() == nil)
}

@Test func identitiesComeFromTheKernel() throws {
    let me = try #require(ProcessIdentity.of(getpid()))
    #expect(me.start > 1_700_000_000_000_000)
    #expect(ProcessIdentity.windowServer() != nil)
}

@Test func windowEntriesKeepEveryField() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    let written = RecoveryRecord(windowServer: identity, manager: ProcessIdentity(pid: 7, start: 9), spaces: [11, 12],
                                 windows: [.init(id: 0xA1B2C3D4, owner: ProcessIdentity(pid: 301, start: 5_000_000_001), originalSpace: 77),
                                           .init(id: 5, owner: ProcessIdentity(pid: 302, start: 6), originalSpace: 0)])
    file.publish(written)
    #expect(try RecordFile(url: url).read() == written)
}

/// The byte layout is what a newer build reads after an older one died. Changing it
/// needs a new format version, so this test pins it.
@Test func recordBytesAreStable() {
    let record = RecoveryRecord(windowServer: ProcessIdentity(pid: 1, start: 2), manager: ProcessIdentity(pid: 3, start: 4),
                                spaces: [5], windows: [.init(id: 6, owner: ProcessIdentity(pid: 7, start: 8), originalSpace: 9)])
    let expected: [UInt8] = [
        0x4d, 0x53, 0x4f, 0x4b, 1, 0, 0, 0,           // magic "KOSM", version 1
        1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,           // WindowServer pid, start
        3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0,           // manager pid, start
        1, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0,           // one Space
        1, 0, 0, 0,                                   // one window:
        6, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0,  // id, owner pid, start, original Space
    ]
    #expect(record.encoded() == expected)
}

@Test func recordBeyondTheDecodersLimitsIsRefused() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try RecordFile(url: url)
    #expect(file.publish(record(spaces: Array(1...64))))
    #expect(!file.publish(record(spaces: Array(1...65))))
    #expect(file.read()?.spaces.count == 64)
}

/// Hiding conceals into the newest recorded Space again only when it still exists and the
/// record names a window: a record without one holds Spaces that outlived their destroy.
@Test func onlyTheNewestSpaceOfARecordWithWindowsIsUsedAgain() {
    #expect(record(spaces: [1, 2], windows: 1).reusableSpace(gone: []) == 2)
    #expect(record(spaces: [1, 2], windows: 1).reusableSpace(gone: [2]) == nil)
    #expect(record(spaces: [1, 2]).reusableSpace(gone: []) == nil)
}
