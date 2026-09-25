import CoreServices

/// The key code of each character the layout types without modifiers, the lowest code where
/// several keys type one. Keypad keys stay out: on French and Czech layouts only the keypad
/// types a digit unshifted, and `alt-1` must fall back to the number row, which a laptop has.
public func keyboardLayout(_ layout: UnsafePointer<UCKeyboardLayout>, keyboardType: UInt32) -> [Character: UInt16] {
    var codes: [Character: UInt16] = [:]
    for code in UInt16(0)..<128 where !keypadCodes.contains(code) {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count,
                                    &length, &characters)
        guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]) else { continue }
        if codes[Character(scalar)] == nil { codes[Character(scalar)] = code }
    }
    return codes
}

/// The keypad's key codes: `kVK_ANSI_Keypad*` and `kVK_JIS_KeypadComma` in HIToolbox's Events.h.
let keypadCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95]
