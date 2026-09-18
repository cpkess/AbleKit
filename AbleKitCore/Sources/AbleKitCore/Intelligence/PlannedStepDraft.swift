import CoreGraphics
import Foundation
import FoundationModels

/// The kinds of step a planner may propose.
///
/// This list is deliberately smaller than `DesktopAction`. It offers the model one obvious way to
/// express each intent and leaves the refinements — whether a click becomes an Accessibility press,
/// for instance — to `CapabilityRouter`, which can decide from context the model does not have.
@Generable(description: "The kind of step to take next")
public enum PlannedActionKind: String, Sendable, CaseIterable {
    /// Launch an application, or bring it forward if it is already running.
    case openApplication
    /// Choose a command listed in MENUS, such as File > New.
    case chooseMenuItem
    /// Click a control listed in CONTROLS, by its id.
    case clickElement
    /// Double-click a control listed in CONTROLS, by its id.
    case doubleClickElement
    /// Right-click a control listed in CONTROLS, by its id.
    case rightClickElement
    /// Click a position on screen. Only when no listed control fits.
    case clickPosition
    /// Type text into whatever currently has keyboard focus.
    case typeText
    /// Press a single key, such as Return or Escape.
    case pressKey
    /// Press a keyboard shortcut, such as Command-S.
    case hotkey
    /// Scroll the current view.
    case scroll
    /// Open a web address.
    case openURL
    /// Ask Microsoft Copilot a question and wait for its answer.
    case askCopilot
    /// Wait for the interface to catch up.
    case wait
    /// Read the text on screen, when CONTROLS do not show what you need.
    case readScreen
    /// Ask the user a question only they can answer.
    case askUser
    /// The goal has been achieved.
    case complete
    /// The goal cannot be achieved.
    case fail
}

/// A keyboard modifier, as the planner names it.
@Generable(description: "A keyboard modifier key")
public enum PlannedModifier: String, Sendable {
    case command
    case shift
    case option
    case control
}

/// One step, as the model produces it.
///
/// Guided generation means the model cannot return prose where an action belongs (brief §7): the
/// shape is enforced by the schema. It can still return a *wrong* step — an id that no longer
/// exists, a key name that means nothing — which is what `PlannedStepDecoder` is for.
///
/// The shape itself is the result of watching the on-device model fail. An earlier version had a
/// separate optional field for every kind of payload — application name, element id, text, key,
/// coordinates, wait time — and the model routinely chose the right kind of step and then left
/// the one field that mattered empty: "open an application" with no application, "choose a menu
/// command" with no command. With each optional field a separate choice to skip, it skipped. So
/// the payload is now a single **required** `subject`, whose meaning depends on the kind, and the
/// only optional fields left are the two genuinely secondary ones.
@Generable(description: "The single next step to take on the Mac")
public struct PlannedStepDraft: Sendable {
    @Guide(description: "What kind of step this is")
    public var kind: PlannedActionKind

    @Guide(
        description:
            "What the step acts on, never empty: the app name, the control or screen text id, the menu path such as File > New, the text to type, the key, the web address, the question, the seconds to wait, the summary when completing, or none"
    )
    public var subject: String

    @Guide(description: "For typeText only: the id of the text field to type into, such as e12")
    public var field: String?

    @Guide(description: "For hotkey only: the modifier keys held down")
    public var modifiers: [PlannedModifier]?

    @Guide(description: "For scroll only: how far, positive to scroll up and negative to scroll down")
    public var scrollAmount: Int?

    @Guide(description: "One short sentence saying why, written for the user to read while waiting")
    public var rationale: String

    public init(
        kind: PlannedActionKind,
        subject: String = "",
        field: String? = nil,
        modifiers: [PlannedModifier]? = nil,
        scrollAmount: Int? = nil,
        rationale: String = ""
    ) {
        self.kind = kind
        self.subject = subject
        self.field = field
        self.modifiers = modifiers
        self.scrollAmount = scrollAmount
        self.rationale = rationale
    }
}

/// How the model judged an action, in a shape the schema can enforce.
@Generable(description: "Whether an action achieved what it was meant to")
public enum VerificationVerdict: String, Sendable {
    case succeeded
    case failed
    case inconclusive
}

@Generable(description: "An ordered plan of the work a goal needs")
public struct TaskPlanDraft: Sendable {
    @Guide(
        description:
            "Between 2 and 8 short sub-goals, in order, each naming one thing that must be true on screen before the next"
    )
    public var steps: [String]

    public init(steps: [String]) {
        self.steps = steps
    }
}

@Generable(description: "Whether the user's goal has been reached")
public struct GoalCheckDraft: Sendable {
    // Evidence first, on purpose: guided generation fills fields in order, so the model must name
    // what it can see before it judges. Asked for the verdict first, it echoed the goal back as
    // though it had happened.
    @Guide(
        description:
            "What on the screen right now shows the goal was carried out, quoting it; or what is missing"
    )
    public var evidence: String

    @Guide(description: "True only if the evidence above shows everything the goal asks for is done")
    public var isAchieved: Bool

    @Guide(description: "One short sentence telling the user what was accomplished")
    public var summary: String

    public init(evidence: String = "", isAchieved: Bool, summary: String = "") {
        self.evidence = evidence
        self.isAchieved = isAchieved
        self.summary = summary
    }
}

@Generable(description: "A judgement about whether an action worked")
public struct VerificationDraft: Sendable {
    @Guide(description: "One short sentence naming what changed on screen, quoting what you can see")
    public var reason: String

    @Guide(description: "The verdict on the action itself")
    public var verdict: VerificationVerdict

    @Guide(
        description:
            "Whether the screen now shows the current sub-goal is finished, so the next one can start"
    )
    public var completedSubGoal: Bool

    @Guide(description: "Whether trying the same action again is worth it")
    public var shouldRetry: Bool

    public init(
        reason: String,
        verdict: VerificationVerdict,
        completedSubGoal: Bool = false,
        shouldRetry: Bool = false
    ) {
        self.reason = reason
        self.verdict = verdict
        self.completedSubGoal = completedSubGoal
        self.shouldRetry = shouldRetry
    }
}
