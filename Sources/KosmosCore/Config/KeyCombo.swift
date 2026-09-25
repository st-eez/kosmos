/// A key combination as a binding names it: modifiers, then one key, joined by '-', such as
/// `alt-shift-h`. Modifier order does not matter.
public struct KeyCombo: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let cmd = Modifiers(rawValue: 1)
        public static let ctrl = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public enum Key: Hashable, Sendable {
        /// A key named by the character it types. The current keyboard layout decides which
        /// physical key that is, so `alt-h` is the key that types h.
        case character(Character)
        /// A key in the same place on every layout, such as an arrow, by macOS virtual key code.
        case code(UInt16)
    }

    public var modifiers: Modifiers
    public var key: Key

    public init(_ text: String) throws(KeyComboError) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains("") else {
            throw KeyComboError("expected modifiers and a key joined by '-', such as alt-shift-h")
        }
        modifiers = try Modifiers(names: parts.dropLast())
        let name = parts[parts.count - 1]
        if let character = characterKeys[name] {
            key = .character(character)
        } else if let code = fixedKeys[name] {
            key = .code(code)
        } else if modifierNames[name] != nil {
            throw KeyComboError("the combination ends in a modifier; add a key such as \(text)-h")
        } else {
            throw KeyComboError("'\(name)' is not a key name"
                + suggestion(for: name, from: Array(characterKeys.keys) + Array(fixedKeys.keys)))
        }
    }

    /// `layout` maps each character the keyboard layout types without modifiers to its key
    /// code. A character it lacks keeps its US keyboard place (docs/hotkeys.md).
    public func physicalKey(layout: [Character: UInt16]) -> PhysicalKey {
        let code = switch key {
        case .character(let character): layout[character] ?? usKeyCodes[character]!
        case .code(let code): code
        }
        return PhysicalKey(code: code, modifiers: modifiers)
    }
}

extension KeyCombo.Modifiers {
    /// Modifiers joined by '-', such as `ctrl-alt`, named as in bindings.
    init(_ text: String) throws(KeyComboError) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains("") else { throw KeyComboError("expected modifiers joined by '-', such as ctrl-alt") }
        try self.init(names: parts[...])
    }

    init(names: ArraySlice<String>) throws(KeyComboError) {
        self = []
        for name in names {
            guard let modifier = modifierNames[name] else {
                throw KeyComboError("'\(name)' is not a modifier; use cmd, ctrl, alt or shift"
                    + suggestion(for: name, from: modifierNames.keys))
            }
            guard !contains(modifier) else { throw KeyComboError("'\(name)' appears twice") }
            insert(modifier)
        }
    }
}

public struct KeyComboError: Error, Equatable {
    public var message: String
    init(_ message: String) { self.message = message }
}

/// A virtual key code with modifiers, the unit Carbon registers a hotkey for.
public struct PhysicalKey: Hashable, Sendable {
    public var code: UInt16
    public var modifiers: KeyCombo.Modifiers

    public init(code: UInt16, modifiers: KeyCombo.Modifiers) {
        self.code = code
        self.modifiers = modifiers
    }
}

private let modifierNames: [String: KeyCombo.Modifiers] = ["cmd": .cmd, "ctrl": .ctrl, "alt": .alt, "shift": .shift]

/// Keys named by the character they type. Letters and digits name themselves
/// (docs/hotkeys.md).
private let characterKeys: [String: Character] = {
    var keys: [String: Character] = [
        "minus": "-", "equal": "=", "leftSquareBracket": "[", "rightSquareBracket": "]", "backslash": "\\",
        "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/", "backtick": "`", "sectionSign": "§",
    ]
    for character in "abcdefghijklmnopqrstuvwxyz0123456789" { keys[String(character)] = character }
    return keys
}()

/// Keys in the same place on every layout, by virtual key code (`kVK_*` in HIToolbox's Events.h).
private let fixedKeys: [String: UInt16] = [
    "space": 49, "enter": 36, "esc": 53, "backspace": 51, "tab": 48, "forwardDelete": 117,
    "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86, "keypad5": 87, "keypad6": 88,
    "keypad7": 89, "keypad8": 91, "keypad9": 92, "keypadClear": 71, "keypadDecimalMark": 65, "keypadDivide": 75,
    "keypadEnter": 76, "keypadEqual": 81, "keypadMinus": 78, "keypadMultiply": 67, "keypadPlus": 69,
]

/// Where each character key sits on a US keyboard (`kVK_ANSI_*`, and `kVK_ISO_Section` for §).
let usKeyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "§": 10, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "`": 50,
]
