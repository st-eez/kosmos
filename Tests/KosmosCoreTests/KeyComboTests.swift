import Testing
@testable import KosmosCore

private func combo(_ text: String) throws -> KeyCombo {
    try KeyCombo(text)
}

private func comboError(_ text: String) -> String? {
    do {
        _ = try KeyCombo(text)
        return nil
    } catch {
        return error.message
    }
}

/// Dvorak types h with the key a US keyboard has j on.
private let dvorak: [Character: UInt16] = ["h": 38]
/// Part of French AZERTY: '-' is on the key a US keyboard has 6 on, and the digits need Shift.
private let azerty: [Character: UInt16] = ["-": 22]

@Suite struct KeyComboTests {
    @Test func modifiersAndKey() throws {
        let parsed = try combo("alt-shift-h")
        #expect(parsed.modifiers == [.alt, .shift])
        #expect(parsed.key == .character("h"))
        #expect(try combo("shift-alt-h") == parsed)
        let hyper = try combo("cmd-ctrl-alt-shift-f19")
        #expect(hyper.modifiers == [.cmd, .ctrl, .alt, .shift] && hyper.key == .code(80))
        #expect(try combo("esc").modifiers.isEmpty)
    }

    @Test func keyNames() throws {
        #expect(try combo("alt-1").key == .character("1"))
        #expect(try combo("alt-minus").key == .character("-"))
        #expect(try combo("alt-equal").key == .character("="))
        #expect(try combo("ctrl-alt-left").key == .code(123))
        #expect(try combo("alt-tab").key == .code(48))
        #expect(try combo("keypadEnter").key == .code(76))
    }

    @Test func badCombinations() {
        #expect(comboError("alt-H") == "'H' is not a key name; did you mean 'h'?")
        #expect(comboError("alt-ecs") == "'ecs' is not a key name; did you mean 'esc'?")
        #expect(comboError("super-h") == "'super' is not a modifier; use cmd, ctrl, alt or shift")
        #expect(comboError("alt-alt-h") == "'alt' appears twice")
        #expect(comboError("alt-shift") == "the combination ends in a modifier; add a key such as alt-shift-h")
        #expect(comboError("alt--h") == "expected modifiers and a key joined by '-', such as alt-shift-h")
        #expect(comboError("") == "expected modifiers and a key joined by '-', such as alt-shift-h")
    }

    @Test func charactersResolveThroughTheLayout() throws {
        let altH = try combo("alt-h")
        #expect(altH.physicalKey(layout: [:]) == PhysicalKey(code: 4, modifiers: .alt))
        #expect(altH.physicalKey(layout: dvorak) == PhysicalKey(code: 38, modifiers: .alt))
        // Arrows are in one place on every layout.
        #expect(try combo("alt-left").physicalKey(layout: dvorak).code == 123)
        // A character the layout lacks keeps its US place: AZERTY types 1 only with Shift.
        #expect(try combo("alt-1").physicalKey(layout: azerty).code == 18)
    }
}
