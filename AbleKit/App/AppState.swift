import AbleKitCore
import AppKit
import Foundation
import SwiftUI
import os

/// Everything the app is, in one place.
///
/// `AppState` is the only object that knows how AbleKit's pieces fit together. Assembling the
/// capability list here — rather than letting each part reach for what it needs — means the set of
/// things AbleKit can do to a Mac is a single readable list, which is a property worth having for
/// software that operates someone's desktop on their behalf.
@MainActor
@Observable
final class AppState {

    let settings: AppSettings
    let permissions: PermissionManager
    let interaction: InteractionCoordinator
    let updates: UpdateController

    /// The running task, if there is one.
    private(set) var session: AgentSession?
    private(set) var skills: [Skill] = []
    /// Set when the local model is unusable, so the palette can say so instead of failing per task.
    private(set) var intelligenceAvailability: IntelligenceAvailability = .available
    /// Set when the chosen shortcut is already taken by another application, so Settings can say
    /// so rather than leaving the user with a key combination that silently does nothing.
    var shortcutRegistrationFailed = false
    /// A Skill chosen from the menu bar that still needs values before it can run.
    ///
    /// The menu cannot collect them, so it hands the Skill to the palette, which can.
    var pendingSkillLaunch: Skill?

    private let intelligence: AppleIntelligenceProvider
    private let collector: ContextCollector
    private let skillStore: SkillStore
    private let skillRunner = SkillRunner()
    private let overlay: OverlayController
    private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.ablekit.AbleKit", category: "Agent")

    init(
        settings: AppSettings = AppSettings(),
        permissions: PermissionManager = PermissionManager(),
        skillStore: SkillStore = SkillStore()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.skillStore = skillStore
        self.interaction = InteractionCoordinator()
        self.intelligence = AppleIntelligenceProvider()
        self.collector = ContextCollector()
        self.updates = UpdateController()
        self.overlay = OverlayController()

        reloadSkills()
    }

    // MARK: - Lifecycle

    func refreshEnvironment() async {
        permissions.refresh()
        intelligenceAvailability = await intelligence.availability
    }

    /// Warms the model so the first step of a task does not pay the load cost.
    func prewarmIntelligence() {
        intelligence.prewarm()
    }

    func reloadSkills() {
        skills = (try? skillStore.load()) ?? []
        // First run: seed the worked examples so the Skills list is not an empty box.
        if skills.isEmpty, !UserDefaults.standard.bool(forKey: "skills.seeded") {
            for sample in Skill.samples { try? skillStore.save(sample) }
            UserDefaults.standard.set(true, forKey: "skills.seeded")
            skills = (try? skillStore.load()) ?? []
        }
    }

    func save(_ skill: Skill) {
        try? skillStore.save(skill)
        reloadSkills()
    }

    func deleteSkill(_ id: UUID) {
        try? skillStore.delete(id)
        reloadSkills()
    }

    // MARK: - Running a task

    var isRunning: Bool {
        session?.phase.isRunning ?? false
    }

    /// Whether a task can be started at all, and why not when it cannot.
    var blockingReason: String? {
        if case .unavailable(let reason, let suggestion) = intelligenceAvailability {
            return [reason, suggestion].compactMap { $0 }.joined(separator: " ")
        }
        if !permissions.isGranted(.accessibility) {
            return "AbleKit needs Accessibility permission before it can operate anything."
        }
        return nil
    }

    func start(goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, blockingReason == nil else { return }

        cancel()
        settings.rememberGoal(trimmed)

        let session = AgentSession(
            goal: trimmed,
            collector: collector,
            intelligence: intelligence,
            executor: Executor(
                router: makeRouter(),
                policy: settings.actionPolicy,
                interaction: interaction
            ),
            verifier: Verifier(intelligence: intelligence),
            interaction: interaction,
            limits: settings.taskLimits
        )
        self.session = session

        log.notice("Task started: \(self.redacted(trimmed), privacy: .public)")
        runTask = Task { [weak self] in
            await session.run()
            self?.finish(session)
        }
        observe(session)
    }

    func run(_ skill: Skill, parameters: [String: String]) {
        do {
            start(goal: try skillRunner.goal(for: skill, parameters: parameters))
        } catch {
            log.error("Could not run the skill: \(String(describing: error), privacy: .public)")
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func cancel() {
        session?.cancel()
        runTask?.cancel()
        runTask = nil
        interaction.dismiss()
        overlay.hide()
    }

    /// Dismisses a finished task's HUD.
    func dismissFinishedTask() {
        guard session?.phase.isTerminal == true else { return }
        session = nil
    }

    private func finish(_ session: AgentSession) {
        overlay.hide()
        guard let termination = session.termination else { return }
        log.notice(
            "Task finished (\(session.phase.rawValue, privacy: .public)) after \(session.history.count) steps: \(self.redacted(termination.userMessage), privacy: .public)"
        )
    }

    // MARK: - Logging

    /// Reports what is frontmost, for checking a task's result from outside it.
    ///
    /// Always public in the log: it is requested explicitly from the terminal, and it reports only
    /// the app and window names.
    func logProbe() async {
        let context = await collector.collect(
            options: ContextCollectionOptions(
                includesAccessibility: true, includesUserContent: false, includesMenus: false,
                maximumElements: 1, maximumDepth: 0
            )
        )
        let app = context.frontmostApplication?.localizedName ?? "none"
        let window = context.focusedWindow?.title ?? "none"
        log.notice("Probe: app=\(app, privacy: .public)|window=\(window, privacy: .public)")
    }

    /// Reports the things that decide whether AbleKit can work at all.
    func logStatus() {
        let accessibility = permissions.status(of: .accessibility).rawValue
        let screen = permissions.status(of: .screenRecording).rawValue
        let intelligence: String
        switch intelligenceAvailability {
        case .available: intelligence = "available"
        case .unavailable(let reason, _): intelligence = "unavailable (\(reason))"
        }
        log.notice(
            "Status: accessibility=\(accessibility, privacy: .public) screenRecording=\(screen, privacy: .public) intelligence=\(intelligence, privacy: .public) shortcut=\(self.settings.shortcut.displayString, privacy: .public)\(self.shortcutRegistrationFailed ? " (unavailable)" : "", privacy: .public) diagnosticLogging=\(self.settings.diagnosticLoggingEnabled ? "on" : "off", privacy: .public)"
        )
    }

    /// Text that may describe the user's screen or intentions is logged only when they have
    /// switched Diagnostic Logging on. Otherwise its length stands in for it, which is still enough
    /// to tell "empty" from "something" when reading a log.
    private func redacted(_ text: String) -> String {
        settings.diagnosticLoggingEnabled ? text : "<\(text.count) characters; enable Diagnostic Logging to see>"
    }

    private func logStep(_ record: StepRecord) {
        let outcome: String
        switch record.outcome {
        case .succeeded: outcome = "succeeded"
        case .failed(let reason): outcome = "failed: \(redacted(reason))"
        case .inconclusive(let reason): outcome = "unverified: \(redacted(reason))"
        case .blocked(let reason): outcome = "blocked: \(reason)"
        case .declined: outcome = "declined by you"
        case .skipped(let reason): outcome = "skipped: \(reason)"
        }
        let action = settings.diagnosticLoggingEnabled
            ? record.action.logSummary
            : record.action.kindName
        log.notice(
            "Step \(record.index + 1): \(action, privacy: .public) via \(record.capability.rawValue, privacy: .public) → \(outcome, privacy: .public)"
        )
    }

    /// Follows a running task: keeps the on-screen highlight on whatever the agent is about to
    /// touch, and logs each step as it completes.
    private func observe(_ session: AgentSession) {
        Task { [weak self, weak session] in
            var loggedSteps = 0
            var lastPhase: AgentPhase?
            while let session, let self {
                if session.phase != lastPhase {
                    lastPhase = session.phase
                    log.info("Phase: \(session.phase.rawValue, privacy: .public)")
                }
                while loggedSteps < session.history.count {
                    logStep(session.history[loggedSteps])
                    loggedSteps += 1
                }
                if session.phase.isTerminal { break }

                if let frame = session.pendingAction?.pointerTarget?.highlightFrame {
                    overlay.show(frame)
                } else {
                    overlay.hide()
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            self?.overlay.hide()
        }
    }

    // MARK: - Developer tools

    /// Collects the desktop context as a task would see it, for the developer inspector.
    ///
    /// Uses the same collector the agent uses, so what the inspector shows is exactly what the
    /// planner would have been given — an inspector with its own code path would be able to
    /// disagree with reality, which is the one thing it must never do.
    func inspectContext(includingScreen: Bool) async -> DesktopContext {
        await collector.collect(options: includingScreen ? .full : .semantic)
    }

    /// Runs a single action through the real pipeline: validation, policy, routing, execution.
    ///
    /// Deliberately not a shortcut around `Executor`. A tester that bypassed the safety gate would
    /// be testing something other than what AbleKit does.
    func testExecute(_ action: DesktopAction, context: DesktopContext) async -> ExecutionReport {
        await Executor(
            router: makeRouter(),
            policy: settings.actionPolicy,
            interaction: interaction
        )
        .execute(action, context: context)
    }

    /// The complete list of things AbleKit can do to this Mac, in preference order.
    private func makeRouter() -> CapabilityRouter {
        CapabilityRouter(capabilities: [
            NativeCapability(),
            AccessibilityCapability(),
            VisualInteractionCapability(),
            AIBridgeCapability(bridges: [CopilotBridge(surface: AccessibilityCopilotSurface())]),
            ControlCapability(interaction: interaction),
        ])
    }
}

extension PointerTarget {
    /// The rectangle the overlay should draw around, in canonical screen coordinates.
    var highlightFrame: CGRect? {
        switch self {
        case .element(let element):
            element.frame.width > 0 ? element.frame : nil
        case .point(let point):
            CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        }
    }
}

extension DesktopAction {
    /// A description safe for a log: controls are named, but text being typed or sent elsewhere is
    /// reduced to its length.
    var logSummary: String {
        switch self {
        case .typeText(let text, let field):
            "Typing \(text.count) characters" + (field.map { " into \($0.description)" } ?? "")
        case .askAIBridge(let bridge, let prompt):
            "Asking \(bridge.displayName) (\(prompt.count) characters)"
        case .requestUserInput: "Asking you a question"
        case .nativeAction(.setClipboard(let text)): "Copying \(text.count) characters"
        default: summary
        }
    }

    /// Just the kind of action, with nothing about what it acted on.
    var kindName: String {
        switch self {
        case .openApplication: "openApplication"
        case .activateApplication: "activateApplication"
        case .click: "click"
        case .doubleClick: "doubleClick"
        case .rightClick: "rightClick"
        case .movePointer: "movePointer"
        case .typeText: "typeText"
        case .pressKey: "pressKey"
        case .hotkey: "hotkey"
        case .scroll: "scroll"
        case .drag: "drag"
        case .wait: "wait"
        case .accessibilityAction(_, let action): "accessibility \(action)"
        case .chooseMenuItem: "chooseMenuItem"
        case .readScreen: "readScreen"
        case .nativeAction: "nativeAction"
        case .askAIBridge(let bridge, _): "ask \(bridge.rawValue)"
        case .requestConfirmation: "requestConfirmation"
        case .requestUserInput: "requestUserInput"
        case .complete: "complete"
        case .fail: "fail"
        }
    }
}
