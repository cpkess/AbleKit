import AbleKitCore
import CoreGraphics
import Foundation
import SwiftUI

/// The handful of things the user can change.
///
/// Settings are kept deliberately small (brief §27). Every option is a decision the user is being
/// asked to make about how an agent behaves on their machine, and a long list of them is a sign
/// that the defaults are not good enough.
@MainActor
@Observable
public final class AppSettings {

    // MARK: - General

    public var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin)
            LoginItem.setEnabled(launchAtLogin)
        }
    }

    public var showsMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }

    public var shortcut: KeyboardShortcutSetting {
        didSet { shortcut.write(to: UserDefaults.standard) }
    }

    // MARK: - Automation

    public var maximumSteps: Int {
        didSet { UserDefaults.standard.set(maximumSteps, forKey: Key.maximumSteps) }
    }

    /// Pause after each action, letting the interface settle before AbleKit looks again.
    public var actionDelay: Double {
        didSet { UserDefaults.standard.set(actionDelay, forKey: Key.actionDelay) }
    }

    public var confirmsConsequentialActions: Bool {
        didSet {
            UserDefaults.standard.set(
                confirmsConsequentialActions, forKey: Key.confirmsConsequentialActions
            )
        }
    }

    // MARK: - Privacy

    public var diagnosticLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticLoggingEnabled, forKey: Key.diagnosticLogging)
        }
    }

    // MARK: - Updates

    public var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticallyChecksForUpdates, forKey: Key.automaticUpdateChecks
            )
        }
    }

    // MARK: - Developer

    public var showsDebugInterface: Bool {
        didSet { UserDefaults.standard.set(showsDebugInterface, forKey: Key.showsDebugInterface) }
    }

    public init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.showsMenuBarIcon: true,
            Key.maximumSteps: TaskLimits.default.maximumSteps,
            Key.actionDelay: TaskLimits.default.actionDelay,
            Key.confirmsConsequentialActions: true,
            Key.automaticUpdateChecks: true,
        ])

        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        shortcut = KeyboardShortcutSetting.read(from: defaults)
        maximumSteps = defaults.integer(forKey: Key.maximumSteps)
        actionDelay = defaults.double(forKey: Key.actionDelay)
        confirmsConsequentialActions = defaults.bool(forKey: Key.confirmsConsequentialActions)
        diagnosticLoggingEnabled = defaults.bool(forKey: Key.diagnosticLogging)
        automaticallyChecksForUpdates = defaults.bool(forKey: Key.automaticUpdateChecks)
        showsDebugInterface = defaults.bool(forKey: Key.showsDebugInterface)
    }

    /// The limits a new task runs under.
    public var taskLimits: TaskLimits {
        TaskLimits(
            maximumSteps: maximumSteps,
            actionDelay: actionDelay
        )
    }

    public var actionPolicy: ActionPolicy {
        ActionPolicy(confirmsConsequentialActions: confirmsConsequentialActions)
    }

    /// Wipes everything AbleKit has kept about past tasks.
    ///
    /// There is not much to wipe, which is the point: task history lives in memory for the
    /// lifetime of a session and screenshots are never written down at all.
    public func clearTaskHistory() {
        UserDefaults.standard.removeObject(forKey: Key.lastGoals)
    }

    public var recentGoals: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.lastGoals) ?? [] }
        set {
            UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: Key.lastGoals)
        }
    }

    public func rememberGoal(_ goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var goals = recentGoals.filter { $0 != trimmed }
        goals.insert(trimmed, at: 0)
        recentGoals = goals
    }

    private enum Key {
        static let launchAtLogin = "general.launchAtLogin"
        static let showsMenuBarIcon = "general.showsMenuBarIcon"
        static let maximumSteps = "automation.maximumSteps"
        static let actionDelay = "automation.actionDelay"
        static let confirmsConsequentialActions = "automation.confirmsConsequentialActions"
        static let diagnosticLogging = "privacy.diagnosticLogging"
        static let automaticUpdateChecks = "updates.automaticChecks"
        static let showsDebugInterface = "developer.showsDebugInterface"
        static let lastGoals = "history.recentGoals"
    }
}

/// The global shortcut, stored as a key code and modifier mask.
public struct KeyboardShortcutSetting: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-Space: unused by macOS itself, and reachable one-handed.
    public static let `default` = KeyboardShortcutSetting(
        keyCode: 49,  // Space
        modifiers: UInt32(controlKeyMask | optionKeyMask)
    )

    static let controlKeyMask = 1 << 12
    static let optionKeyMask = 1 << 11
    static let commandKeyMask = 1 << 8
    static let shiftKeyMask = 1 << 9

    public var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(Self.controlKeyMask) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(Self.optionKeyMask) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(Self.shiftKeyMask) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(Self.commandKeyMask) != 0 { parts.append("\u{2318}") }
        parts.append(Self.name(for: keyCode))
        return parts.joined()
    }

    /// The name of a key, read from the layout the user is actually typing on.
    ///
    /// Named keys come first because they have fixed codes; everything else is asked of the live
    /// keyboard layout, so a shortcut reads correctly on a non-US keyboard.
    static func name(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 123: return "\u{2190}"
        case 124: return "\u{2192}"
        case 125: return "\u{2193}"
        case 126: return "\u{2191}"
        default:
            return KeyboardLayout.current.character(forKeyCode: CGKeyCode(keyCode))?.uppercased()
                ?? "Key \(keyCode)"
        }
    }

    static func read(from defaults: UserDefaults) -> KeyboardShortcutSetting {
        guard defaults.object(forKey: "shortcut.keyCode") != nil else { return .default }
        return KeyboardShortcutSetting(
            keyCode: UInt32(defaults.integer(forKey: "shortcut.keyCode")),
            modifiers: UInt32(defaults.integer(forKey: "shortcut.modifiers"))
        )
    }

    func write(to defaults: UserDefaults) {
        defaults.set(Int(keyCode), forKey: "shortcut.keyCode")
        defaults.set(Int(modifiers), forKey: "shortcut.modifiers")
    }
}
