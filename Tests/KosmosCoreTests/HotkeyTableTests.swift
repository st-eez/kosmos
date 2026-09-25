import Testing
@testable import KosmosCore

/// Through the loader, so every command is one the parser accepts.
private func modes(_ tables: String) throws -> [String: [Binding]] {
    let result = Config.load("config-version = 1\nworkspaces = ['1']\n" + tables)
    #expect(result.diagnostics.isEmpty)
    return try #require(result.config).modes
}

@Suite struct HotkeyTableTests {
    @Test @MainActor func bindingsOnOnePhysicalKeyCollide() throws {
        let bindings = try #require(try modes("""
        [mode.main.binding]
        alt-sectionSign = 'resize smart -100'
        alt-6 = 'workspace 6'
        """)["main"])
        let us = HotkeyTable(bindings, layout: [:])
        #expect(us.bindings.count == 2 && us.collisions.isEmpty)
        // French types § with the key a US keyboard has 6 on, and 6 only with Shift.
        let french = HotkeyTable(bindings, layout: try installedLayout("com.apple.keylayout.French"))
        #expect(french.bindings[PhysicalKey(code: 22, modifiers: .alt)]?.key == "alt-sectionSign")
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
        #expect(resize.bindings[PhysicalKey(code: 4, modifiers: .alt)]?.command == .resize(.width, by: -50))
        let none = main.changes(from: main.bindings.keys)
        #expect(none.unregister.isEmpty && none.register.isEmpty)
    }

    @Test @MainActor func layoutChangeMovesOnlyCharacterKeys() throws {
        let bindings = try #require(try modes("""
        [mode.main.binding]
        alt-h = 'focus left'
        alt-left = 'focus left'
        alt-1 = 'workspace 1'
        """)["main"])
        let us = HotkeyTable(bindings, layout: [:])
        let dvorak = try installedLayout("com.apple.keylayout.Dvorak")
        let changes = HotkeyTable(bindings, layout: dvorak).changes(from: us.bindings.keys)
        #expect(changes.unregister == [PhysicalKey(code: 4, modifiers: .alt)])
        #expect(changes.register == [PhysicalKey(code: 38, modifiers: .alt)])
    }

    @Test func failedRegistrationsAreRetried() throws {
        let bindings = try #require(try modes("[mode.main.binding]\nalt-h = 'focus left'")["main"])
        #expect(HotkeyTable(bindings, layout: [:]).changes(from: []).register == [PhysicalKey(code: 4, modifiers: .alt)])
    }
}
