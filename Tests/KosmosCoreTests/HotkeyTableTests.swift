import Testing
@testable import KosmosCore

private func binding(_ key: String, _ command: String) throws -> Binding {
    Binding(key: key, combo: try KeyCombo(key), command: .string(command))
}

/// Dvorak types h with the key a US keyboard has j on.
private let dvorak: [Character: UInt16] = ["h": 38]
/// Part of French AZERTY: '-' is on the key a US keyboard has 6 on, and the digits need Shift.
private let azerty: [Character: UInt16] = ["-": 22]

@Suite struct HotkeyTableTests {
    @Test func bindingsOnOnePhysicalKeyCollide() throws {
        let bindings = [try binding("alt-minus", "resize smart -100"), try binding("alt-6", "workspace 6")]
        let us = HotkeyTable(bindings, layout: [:])
        #expect(us.bindings.count == 2 && us.collisions.isEmpty)
        let french = HotkeyTable(bindings, layout: azerty)
        #expect(french.bindings[PhysicalKey(code: 22, modifiers: .alt)]?.key == "alt-minus")
        #expect(french.collisions == [HotkeyTable.Collision(kept: bindings[0], dropped: bindings[1])])
    }

    @Test func modeSwitchTouchesOnlyTheKeysThatDiffer() throws {
        let main = HotkeyTable([
            try binding("alt-h", "focus left"),
            try binding("alt-l", "focus right"),
            try binding("alt-r", "mode resize"),
        ], layout: [:])
        let resize = HotkeyTable([
            try binding("alt-h", "resize width -50"),
            try binding("alt-l", "resize width +50"),
            try binding("esc", "mode main"),
        ], layout: [:])
        let changes = resize.changes(from: main.bindings.keys)
        #expect(changes.unregister == [PhysicalKey(code: 15, modifiers: .alt)])
        #expect(changes.register == [PhysicalKey(code: 53, modifiers: [])])
        // alt-h stays registered; the new table supplies its new command.
        #expect(resize.bindings[PhysicalKey(code: 4, modifiers: .alt)]?.command == .string("resize width -50"))
        // The same table twice changes nothing.
        let none = main.changes(from: main.bindings.keys)
        #expect(none.unregister.isEmpty && none.register.isEmpty)
    }

    @Test func layoutChangeMovesOnlyCharacterKeys() throws {
        let bindings = [try binding("alt-h", "focus left"), try binding("alt-left", "focus left"), try binding("alt-1", "workspace 1")]
        let us = HotkeyTable(bindings, layout: [:])
        let changes = HotkeyTable(bindings, layout: dvorak).changes(from: us.bindings.keys)
        #expect(changes.unregister == [PhysicalKey(code: 4, modifiers: .alt)])
        #expect(changes.register == [PhysicalKey(code: 38, modifiers: .alt)])
    }

    @Test func failedRegistrationsAreRetried() throws {
        // Changes are computed against what is registered, so a key that failed to register
        // last time is registered again.
        let table = HotkeyTable([try binding("alt-h", "focus left")], layout: [:])
        #expect(table.changes(from: []).register == [PhysicalKey(code: 4, modifiers: .alt)])
    }
}
