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
@Generable(description: "The single next step to take on the Mac")
public struct PlannedStepDraft: Sendable {
    @Guide(description: "What kind of step this is")
    public var kind: PlannedActionKind

    @Guide(description: "One short sentence saying why, written for the user to read while waiting")
    public var rationale: String

    @Guide(description: "For openApplication: the name of the application, such as Safari")
    public var applicationName: String?

    @Guide(description: "For the element steps and scroll: the id in square brackets from CONTROLS, such as e12")
    public var elementID: String?

    @Guide(
        description:
            "The text this step needs: what to type, the web address to open, the question to ask Copilot or the user, or the summary when completing"
    )
    public var text: String?

    @Guide(description: "For pressKey and hotkey: the key, such as return, escape, tab, or a single letter")
    public var keyName: String?

    @Guide(description: "For hotkey: the modifiers held down with the key")
    public var modifiers: [PlannedModifier]?

    @Guide(description: "For clickPosition: the horizontal screen position in points")
    public var x: Double?

    @Guide(description: "For clickPosition: the vertical screen position in points")
    public var y: Double?

    @Guide(description: "For scroll: how far, positive to scroll up and negative to scroll down")
    public var scrollAmount: Int?

    @Guide(description: "For wait: how many seconds, at most 10")
    public var waitSeconds: Double?

    @Guide(description: "How confident you are in this step, from 0 to 1")
    public var confidence: Double

    public init(
        kind: PlannedActionKind,
        rationale: String,
        applicationName: String? = nil,
        elementID: String? = nil,
        text: String? = nil,
        keyName: String? = nil,
        modifiers: [PlannedModifier]? = nil,
        x: Double? = nil,
        y: Double? = nil,
        scrollAmount: Int? = nil,
        waitSeconds: Double? = nil,
        confidence: Double = 1
    ) {
        self.kind = kind
        self.rationale = rationale
        self.applicationName = applicationName
        self.elementID = elementID
        self.text = text
        self.keyName = keyName
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.scrollAmount = scrollAmount
        self.waitSeconds = waitSeconds
        self.confidence = confidence
    }
}

/// How the model judged an action, in a shape the schema can enforce.
@Generable(description: "Whether an action achieved what it was meant to")
public enum VerificationVerdict: String, Sendable {
    case succeeded
    case failed
    case inconclusive
}

@Generable(description: "A judgement about whether an action worked")
public struct VerificationDraft: Sendable {
    @Guide(description: "The verdict")
    public var verdict: VerificationVerdict

    @Guide(description: "One short sentence naming what you observed that settles it")
    public var reason: String

    @Guide(description: "Whether trying the same action again is worth it")
    public var shouldRetry: Bool

    public init(verdict: VerificationVerdict, reason: String, shouldRetry: Bool = false) {
        self.verdict = verdict
        self.reason = reason
        self.shouldRetry = shouldRetry
    }
}
