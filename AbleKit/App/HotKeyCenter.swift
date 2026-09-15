import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers the system-wide shortcut that summons AbleKit.
///
/// Carbon's `RegisterEventHotKey` is used rather than an `NSEvent` global monitor, for two reasons
/// that matter here: it needs no Accessibility permission — so the shortcut works before onboarding
/// is finished — and it *consumes* the keystroke, so the key combination does not also reach
/// whatever application the user is looking at.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    /// Registers `shortcut`, replacing any previously registered one.
    ///
    /// - Returns: `false` if the combination is already taken by another application, so the UI can
    ///   tell the user rather than leaving them with a shortcut that silently does nothing.
    @discardableResult
    func register(_ shortcut: KeyboardShortcutSetting, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr else { return false }
        hotKeyReference = reference
        return true
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
                // The Carbon callback is a C function pointer and so cannot capture context; the
                // work is hopped onto the main actor, where the rest of the UI lives.
                MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    private static let signature: OSType = {
        let characters = Array("ABLE".utf8)
        return OSType(characters[0]) << 24 | OSType(characters[1]) << 16 | OSType(characters[2]) << 8
            | OSType(characters[3])
    }()
}
