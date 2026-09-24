import Testing
@testable import KosmosCore

/// Each mode's bindings from `[mode.*.binding]` tables, through the loader, so every command
/// is one the parser accepts.
private func modes(_ tables: String) throws -> [String: [Binding]] {
    let result = Config.load("config-version = 1\nworkspaces = ['1']\n" + tables)
    #expect(result.diagnostics.isEmpty)
    return try #require(result.config).modes
}

/// Dvorak types h with the key a US keyboard has j on.
private let dvorak: [Character: UInt16] = ["h": 38]
/// Part of French AZERTY: '-' is on the key a US keyboard has 6 on, and the digits need Shift.
private let azerty: [Character: UInt16] = ["-": 22]

@Suite struct HotkeyTableTests {
    @Test func bindingsOnOnePhysicalKeyCollide() throws {
        let bindings = try #require(try modes("""
        [mode.main.binding]
        alt-minus = 'resize smart -100'
        alt-6 = 'workspace 6'
        """)["main"])
        let us = HotkeyTable(bindings, layout: [:])
        #expect(us.bindings.count == 2 && us.collisions.isEmpty)
        let french = HotkeyTable(bindings, layout: azerty)
        #expect(french.bindings[PhysicalKey(code: 22, modifiers: .alt)]?.key == "alt-minus")
        #expect(french.collisions == [HotkeyTable.Collision(kept: bindings[0], dropped: bindings[1])])
    }

    @Test func modeSwitchTouchesOnlyTheKeysThatDiffer() throws {
        let modes = try modes("""
        [mode.main.binding]
        alt-h = 'focus left'
        alt-l = 'focus right'
        alt-r = 'mode resize'
        [mode.resize.binding]
        alt-h = 'resize width -50'
        alt-l = 'resize width +50'
        esc = 'mode main'
        """)
        let main = HotkeyTable(modes["main"] ?? [], layout: [:])
        let resize = HotkeyTable(modes["resize"] ?? [], layout: [:])
        let changes = resize.changes(from: main.bindings.keys)
        #expect(changes.unregister == [PhysicalKey(code: 15, modifiers: .alt)])
        #expect(changes.register == [PhysicalKey(code: 53, modifiers: [])])
        // alt-h stays registered; the new table supplies its new command.
        #expect(resize.bindings[PhysicalKey(code: 4, modifiers: .alt)]?.arguments == ["resize", "width", "-50"])
        // The same table twice changes nothing.
        let none = main.changes(from: main.bindings.keys)
        #expect(none.unregister.isEmpty && none.register.isEmpty)
    }

    @Test func layoutChangeMovesOnlyCharacterKeys() throws {
        let bindings = try #require(try modes("""
        [mode.main.binding]
        alt-h = 'focus left'
        alt-left = 'focus left'
        alt-1 = 'workspace 1'
        """)["main"])
        let us = HotkeyTable(bindings, layout: [:])
        let changes = HotkeyTable(bindings, layout: dvorak).changes(from: us.bindings.keys)
        #expect(changes.unregister == [PhysicalKey(code: 4, modifiers: .alt)])
        #expect(changes.register == [PhysicalKey(code: 38, modifiers: .alt)])
    }

    @Test func failedRegistrationsAreRetried() throws {
        // Changes are computed against what is registered, so a key that failed to register
        // last time is registered again.
        let bindings = try #require(try modes("[mode.main.binding]\nalt-h = 'focus left'")["main"])
        #expect(HotkeyTable(bindings, layout: [:]).changes(from: []).register == [PhysicalKey(code: 4, modifiers: .alt)])
    }
}
