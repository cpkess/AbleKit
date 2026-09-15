import Foundation

/// What AbleKit can see of Copilot's interface at one moment.
public struct CopilotInterface: Sendable, Equatable {
    /// Where the question is typed.
    public let promptField: ElementReference?
    /// The control that sends it, where one is exposed. Many chat interfaces submit on Return
    /// instead, so this is optional rather than required.
    public let submitControl: ElementReference?
    /// The conversation text currently displayed.
    public let responseText: String
    /// Whether the interface is visibly working — a stop button, a progress indicator.
    public let isBusy: Bool
    /// The control that switches to the deeper research mode, if this build exposes one.
    public let researcherControl: ElementReference?

    public init(
        promptField: ElementReference? = nil,
        submitControl: ElementReference? = nil,
        responseText: String = "",
        isBusy: Bool = false,
        researcherControl: ElementReference? = nil
    ) {
        self.promptField = promptField
        self.submitControl = submitControl
        self.responseText = responseText
        self.isBusy = isBusy
        self.researcherControl = researcherControl
    }
}

/// The operations the bridge needs to perform against Copilot's interface.
///
/// Extracted as a protocol so the bridge's conversation logic — which is the hard, stateful,
/// get-it-wrong-in-production part — can be tested exhaustively against a scripted interface,
/// on a machine where Copilot is not even installed.
public protocol CopilotSurface: Sendable {
    /// Whether the application is installed.
    var isInstalled: Bool { get }
    /// Brings Copilot forward, launching it if necessary.
    func activate() async throws
    /// Reads the interface as it stands now.
    func readInterface() async throws -> CopilotInterface
    /// Puts the prompt into the field.
    func enterPrompt(_ text: String, into field: ElementReference) async throws
    /// Sends it.
    func submit(_ interface: CopilotInterface) async throws
    /// Switches interaction mode. Throws if the mode's affordance is not present.
    func selectMode(_ mode: CopilotMode, using control: ElementReference) async throws
}

/// Decides when a streaming answer has finished.
///
/// A chat interface gives no completion signal that can be relied on: the busy indicator is not
/// always exposed, and the text arrives in pieces. What can be observed is that the answer stops
/// changing. This tracks that, and distinguishes the three states that matter — still arriving,
/// settled, and never started — which is what lets the bridge report "Copilot did not answer"
/// rather than returning half a sentence.
public struct ResponseStabilityDetector: Sendable {
    /// How many consecutive identical readings mean the answer has settled.
    public let requiredStableReadings: Int

    private var lastText: String?
    private var stableCount = 0
    private var hasSeenContent = false

    public init(requiredStableReadings: Int = 3) {
        self.requiredStableReadings = requiredStableReadings
    }

    public enum Progress: Sendable, Equatable {
        /// The answer is still arriving, or has not started.
        case pending
        /// The answer has stopped changing.
        case settled(String)
    }

    /// Feeds in one reading of the interface.
    public mutating func observe(text: String, isBusy: Bool) -> Progress {
        let trimmed = text.trimmed

        if !trimmed.isEmpty { hasSeenContent = true }

        // While the interface says it is working, the answer is not final however stable it looks:
        // a pause between tokens is not the end of the reply.
        if isBusy {
            stableCount = 0
            lastText = trimmed
            return .pending
        }

        guard hasSeenContent else {
            lastText = trimmed
            return .pending
        }

        if trimmed == lastText {
            stableCount += 1
        } else {
            stableCount = 1
            lastText = trimmed
        }

        return stableCount >= requiredStableReadings ? .settled(trimmed) : .pending
    }

    /// Whatever has been seen so far, for reporting a timeout honestly.
    public var observedText: String? {
        hasSeenContent ? lastText : nil
    }
}
