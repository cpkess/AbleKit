import AppKit
import SwiftUI

/// Lets the user set the shortcut that summons AbleKit by pressing it.
///
/// Recording the combination is the only honest way to offer this: a pair of pop-up menus would
/// let someone choose something their keyboard cannot actually produce, and would not tell them
/// when macOS or another app has already claimed it.
///
/// While recording, a **local** event monitor swallows keystrokes so the combination does not also
/// reach the Settings window underneath — pressing Command-W to set a shortcut should not close the
/// window you are setting it in.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcutSetting
    /// Called after a new shortcut is stored, so the hot key can be re-registered.
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press a shortcut\u{2026}" : shortcut.displayString)
                .font(.body.monospaced())
                .frame(minWidth: 120)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .help(isRecording ? "Press the combination you want, or Escape to cancel" : "Click to change")
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape abandons the recording rather than becoming the shortcut.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
            // A shortcut with no modifier would fire whenever the user typed that letter anywhere.
            guard carbonModifiers != 0 else { return nil }

            shortcut = KeyboardShortcutSetting(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers
            )
            stopRecording()
            onChange()
            return nil  // swallow it, so it does not reach the window underneath
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Converts AppKit's modifier flags into the Carbon mask `RegisterEventHotKey` expects.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: Int = 0
        if flags.contains(.command) { mask |= KeyboardShortcutSetting.commandKeyMask }
        if flags.contains(.shift) { mask |= KeyboardShortcutSetting.shiftKeyMask }
        if flags.contains(.option) { mask |= KeyboardShortcutSetting.optionKeyMask }
        if flags.contains(.control) { mask |= KeyboardShortcutSetting.controlKeyMask }
        return UInt32(mask)
    }
}
