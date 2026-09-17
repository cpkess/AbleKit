import AppKit
import Foundation
import Sparkle
import SwiftUI
import os

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

    /// Whether Sparkle will currently allow a check.
    private(set) var canCheckForUpdates = false

    /// A version found by a background check that the user has not looked at yet.
    ///
    /// AbleKit lives in the menu bar and is almost never the active app, so an update alert from a
    /// scheduled check opens behind whatever the user is doing and is easily missed. Sparkle calls
    /// the answer to that "gentle reminders"; here it is an item at the top of the menu.
    private(set) var availableVersion: String?

    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let log = Logger(subsystem: "com.ablekit.AbleKit", category: "Updates")

    init() {
        // Started manually, after the delegate knows who to report to, so no result from the
        // first scheduled check can arrive before there is anywhere to put it.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        delegate.owner = self
        controller.startUpdater()

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
    /// plainly rather than showing a Check button that can only fail.
    var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Checks now, showing the result whether or not an update exists.
    ///
    /// AbleKit has no Dock icon and is almost never the active app, so it is activated first —
    /// otherwise Sparkle's window opens behind whatever the user is looking at, and the button
    /// appears to do nothing.
    func checkForUpdates() {
        NSApp.activate()
        log.notice("Checking for updates (current: \(self.currentVersion, privacy: .public))")
        controller.updater.checkForUpdates()
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "0.0.0") (\(build ?? "0"))"
    }

    // MARK: - Reports from Sparkle

    fileprivate func found(_ item: SUAppcastItem) {
        log.notice(
            "Update found: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))"
        )
    }

    fileprivate func noUpdate(_ error: any Error) {
        let reason = (error as NSError).localizedDescription
        log.notice("No update: \(reason, privacy: .public)")
    }

    fileprivate func aborted(_ error: any Error) {
        log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
    }

    fileprivate func remind(about item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    fileprivate func clearReminder() {
        availableVersion = nil
    }
}

/// Sparkle's delegate protocols require an Objective-C object, which `UpdateController` is not.
///
/// `SPUStandardUserDriverDelegate` has no concurrency annotations, but Sparkle's standard user driver
/// only ever calls it on the main thread. `@preconcurrency` records that assumption and checks it at
/// runtime, rather than dropping the main-actor isolation this class needs.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    weak var owner: UpdateController?

    // MARK: Results

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.found(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        owner?.noUpdate(error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        owner?.aborted(error)
    }

    // MARK: Gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A check the user asked for shows its window in front already; only background checks
        // need the reminder.
        guard !state.userInitiated else { return }
        owner?.remind(about: update)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        owner?.clearReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.clearReminder()
    }
}
