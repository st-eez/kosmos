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
