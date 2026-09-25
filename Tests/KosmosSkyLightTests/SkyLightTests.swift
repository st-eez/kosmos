import Testing
@testable import KosmosSkyLight

/// The check names classes and initializers this macOS has, so a typo in it would turn hiding
/// off here too.
@Test func thisMacOSHasEveryBridgedOperation() {
    #expect(SkyLight.missingBridgedOperation == nil)
}

/// A window event carries the window id at offset 0, and a Space membership event at offset 8,
/// after a 64 bit Space id. A payload too short for it gives no event.
@Test func eventsReadTheWindowAtTheirOffset() {
    var bytes = [UInt8](repeating: 0, count: 12)
    bytes.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(77).littleEndian, Array.init))
    bytes.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(88).littleEndian, Array.init))
    bytes.withUnsafeBytes { payload in
        #expect(WindowServerEvent(id: 806, payload: payload)?.window == 77)
        #expect(WindowServerEvent(id: 1325, payload: payload)?.window == 88)
        #expect(WindowServerEvent(id: 1327, payload: payload)?.window == nil)
        #expect(WindowServerEvent(id: 999, payload: payload) == nil)
    }
    bytes.prefix(8).withUnsafeBytes { payload in
        #expect(WindowServerEvent(id: 804, payload: payload)?.window == 77)
        #expect(WindowServerEvent(id: 1326, payload: payload) == nil)
    }
    bytes.prefix(3).withUnsafeBytes { #expect(WindowServerEvent(id: 811, payload: $0) == nil) }
}
