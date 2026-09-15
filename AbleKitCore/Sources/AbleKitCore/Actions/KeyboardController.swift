import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Sends synthetic keyboard input.
///
/// Two different mechanisms are used, on purpose:
///
/// - **Typing text** posts the characters directly as a Unicode payload. That works for every
///   character in every language without knowing anything about the user's keyboard layout, and it
///   is the only approach that can type "é" or "日本語" correctly.
/// - **Pressing keys and shortcuts** must use real virtual key codes, because that is what
///   applications match their menu shortcuts against. Those codes are resolved against the layout
///   the user is actually typing on, so Command-S is the S *they* have, not the one on a US board.
public struct KeyboardController: Sendable {

    private static let tap = CGEventTapLocation.cghidEventTap

    public init() {}

    /// Types text into whatever currently has keyboard focus.
    public func type(_ text: String) throws(CapabilityError) {
        // Long strings are sent in chunks: a single event with a very large payload is unreliable,
        // and chunking also gives the receiving app time to keep up.
        for chunk in text.chunked(into: 20) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                throw .permissionRequired(.accessibility)
            }
            let characters = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            down.post(tap: Self.tap)
            up.post(tap: Self.tap)
        }
    }

    /// Presses a single key.
    public func press(_ key: Key, modifiers: [ModifierKey] = []) throws(CapabilityError) {
        guard let keyCode = KeyboardLayout.current.keyCode(for: key) else {
            throw .executionFailed("There is no key for \(key.displayName) on this keyboard.")
        }
        let flags = CGEventFlags(modifiers)

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw .permissionRequired(.accessibility)
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: Self.tap)
        up.post(tap: Self.tap)
    }
}

/// Resolves symbolic keys to the virtual key codes of the current keyboard layout.
///
/// Named keys (Return, Tab, the arrows) have fixed codes that never move. Characters do move:
/// the physical key that produces "z" is in a different place on a French layout than a US one, and
/// hard-coding US codes would make Command-Z do the wrong thing for anyone not typing in English.
struct KeyboardLayout: Sendable {
    private let characterToKeyCode: [String: CGKeyCode]

    /// The layout the user is typing on right now.
    ///
    /// Read fresh each time rather than cached: input sources can be switched at any moment, and a
    /// stale map would silently send the wrong key.
    static var current: KeyboardLayout {
        KeyboardLayout(characterToKeyCode: Self.buildCharacterMap())
    }

    func keyCode(for key: Key) -> CGKeyCode? {
        switch key {
        case .character(let character):
            return characterToKeyCode[character.lowercased()]
        case .returnKey: return CGKeyCode(kVK_Return)
        case .enterKey: return CGKeyCode(kVK_ANSI_KeypadEnter)
        case .tab: return CGKeyCode(kVK_Tab)
        case .space: return CGKeyCode(kVK_Space)
        case .delete: return CGKeyCode(kVK_Delete)
        case .forwardDelete: return CGKeyCode(kVK_ForwardDelete)
        case .escape: return CGKeyCode(kVK_Escape)
        case .arrowUp: return CGKeyCode(kVK_UpArrow)
        case .arrowDown: return CGKeyCode(kVK_DownArrow)
        case .arrowLeft: return CGKeyCode(kVK_LeftArrow)
        case .arrowRight: return CGKeyCode(kVK_RightArrow)
        case .home: return CGKeyCode(kVK_Home)
        case .end: return CGKeyCode(kVK_End)
        case .pageUp: return CGKeyCode(kVK_PageUp)
        case .pageDown: return CGKeyCode(kVK_PageDown)
        case .function(let number): return Self.functionKeyCode(number)
        }
    }

    /// Builds a character-to-key-code map by asking the current layout what each physical key
    /// produces, then inverting the answer.
    private static func buildCharacterMap() -> [String: CGKeyCode] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var map: [String: CGKeyCode] = [:]

        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return }

            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0

            for keyCode in 0..<CGKeyCode(128) {
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    0,  // no modifiers: the unshifted character this key produces
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: characters, count: length)
                guard !string.isEmpty, !string.allSatisfy(\.isWhitespace) else { continue }
                // First key code wins, so that a character available on both the main block and the
                // numeric keypad resolves to the main one.
                if map[string] == nil { map[string] = keyCode }
            }
        }
        return map
    }

    private static func functionKeyCode(_ number: Int) -> CGKeyCode? {
        let codes: [Int: Int] = [
            1: kVK_F1, 2: kVK_F2, 3: kVK_F3, 4: kVK_F4, 5: kVK_F5, 6: kVK_F6,
            7: kVK_F7, 8: kVK_F8, 9: kVK_F9, 10: kVK_F10, 11: kVK_F11, 12: kVK_F12,
            13: kVK_F13, 14: kVK_F14, 15: kVK_F15, 16: kVK_F16, 17: kVK_F17,
            18: kVK_F18, 19: kVK_F19, 20: kVK_F20,
        ]
        return codes[number].map(CGKeyCode.init)
    }
}

extension CGEventFlags {
    init(_ modifiers: [ModifierKey]) {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        self = flags
    }
}

extension String {
    /// Splits the string into pieces of at most `size` characters.
    func chunked(into size: Int) -> [String] {
        guard count > size else { return isEmpty ? [] : [self] }
        var chunks: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if current.count == size {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
