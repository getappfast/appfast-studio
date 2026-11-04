import Foundation

/// US keyboard layout: the USB HID usage (page 7) and Shift state that types a character.
enum KeyboardMap {
    struct Key: Equatable, Sendable {
        let usage: Int32
        var shift = false
    }

    static let returnKey = Key(usage: 0x28)
    static let deleteKey = Key(usage: 0x2A)
    static let tabKey = Key(usage: 0x2B)
    static let escapeKey = Key(usage: 0x29)

    private static let unshifted = Array("abcdefghijklmnopqrstuvwxyz1234567890")
    private static let punctuation: [Character: Int32] = [
        " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31,
        ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]

    /// Nil for a character a US keyboard can't type (emoji, accents).
    static func key(for character: Character) -> Key? {
        if character == "\n" { return returnKey }
        if character == "\t" { return tabKey }
        if let base = shifted[character] { return key(for: base).map { Key(usage: $0.usage, shift: true) } }
        if let letter = character.lowercased().first, let index = unshifted.firstIndex(of: letter) {
            // Letters a-z are usages 4...29, then 1-9 are 30...38 and 0 is 39, which is the order of `unshifted`.
            return Key(usage: Int32(index + 4), shift: character.isUppercase)
        }
        return punctuation[character].map { Key(usage: $0) }
    }

    /// The keys that type `text`, and the characters that couldn't be typed.
    static func keys(for text: String) -> (keys: [Key], skipped: [Character]) {
        var keys: [Key] = [], skipped: [Character] = []
        for character in text {
            if let key = key(for: character) { keys.append(key) } else { skipped.append(character) }
        }
        return (keys, skipped)
    }

    static func named(_ name: String) -> Key? {
        switch name {
        case "return", "enter": returnKey
        case "delete", "backspace": deleteKey
        case "tab": tabKey
        case "escape", "esc": escapeKey
        default: nil
        }
    }
}
