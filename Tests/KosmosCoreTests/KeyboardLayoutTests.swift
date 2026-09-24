import Carbon
import Testing
@testable import KosmosCore

/// A keyboard layout macOS ships, read with the function Hotkeys applies to the current one.
/// Text Input Sources calls must run on the main thread.
@MainActor
func installedLayout(_ id: String) throws -> [Character: UInt16] {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    let source = try #require(sources.first, "\(id) is not installed")
    let data = try #require(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
    let bytes = try #require(CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()))
    return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
        // A fixed ANSI keyboard type, so the expectations hold on any Mac: with a JIS
        // keyboard (types 42 and 45) the US layout has no bare `=`.
        keyboardLayout(layout, keyboardType: 40)
    }
}

@Suite struct KeyboardLayoutTests {
    @Test(arguments: [
        ("com.apple.keylayout.US", ["1": 18, "0": 29, "-": 27, "=": 24, "/": 44, "h": 4]),
        // French and Czech type digits only with Shift, and only the keypad types them bare.
        // They stay out of the table, so alt-1 falls back to the number row.
        ("com.apple.keylayout.French", ["1": nil, "0": nil, "/": nil, "-": 24, "§": 22, "a": 12, "q": 0]),
        ("com.apple.keylayout.Czech", ["1": nil, "0": nil, "-": 44, "=": 27, "z": 16, "y": 6]),
        // German types = only with Shift, or bare on the keypad.
        ("com.apple.keylayout.German", ["1": 18, "=": nil, "z": 16, "y": 6]),
    ] as [(String, [Character: UInt16?])])
    @MainActor
    func keyCodesSkipTheKeypad(id: String, expected: [Character: UInt16?]) throws {
        let layout = try installedLayout(id)
        #expect(!layout.values.contains(where: keypadCodes.contains))
        for (character, code) in expected {
            #expect(layout[character] == code, "\(id): \(character)")
        }
    }
}
