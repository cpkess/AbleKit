import Foundation
import Sparkle
import SwiftUI

/// Keeps AbleKit up to date.
///
/// Sparkle is used rather than a hand-rolled updater because the part that matters is the part that
/// is easy to get wrong: an update mechanism is a code-execution channel, and Sparkle verifies an
/// EdDSA signature over every download before it is allowed anywhere near the user's machine. The
/// release workflow signs each build with a key that never leaves the maintainer's keychain.
///
/// If no public key is configured, Sparkle refuses updates outright — which is the correct failure
/// mode, and why the key is checked and surfaced in Settings rather than assumed.
@MainActor
@Observable
final class UpdateController {

    private let controller: SPUStandardUpdaterController

    /// Whether Sparkle will currently allow a check.
    private(set) var canCheckForUpdates = false

    private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // The new value is taken from the change rather than read back off the updater, which is
        // main-actor isolated and cannot be touched from the KVO callback.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDescription: String {
        guard let date = controller.updater.lastUpdateCheckDate else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Whether this build can actually receive updates.
    ///
    /// A build with no public key is not broken, but it will never update, and Settings says so
    /// plainly rather than showing a Check button that can only ever fail.
    var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "0.0.0") (\(build ?? "0"))"
    }
}
