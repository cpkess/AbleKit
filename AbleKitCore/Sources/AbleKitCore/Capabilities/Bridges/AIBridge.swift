import Foundation

/// Identifies an external AI application that AbleKit can delegate reasoning to.
///
/// Bridges are how AbleKit participates in workflows it cannot reason about on its own: the local
/// model understands the desktop, and a bridge supplies knowledge the desktop does not contain.
public struct AIBridgeIdentifier: Sendable, Equatable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Microsoft Copilot, driven through its own authorised user interface.
    public static let copilot = AIBridgeIdentifier(rawValue: "copilot")

    public var displayName: String {
        switch self {
        case .copilot: "Copilot"
        default: rawValue.capitalized
        }
    }
}

/// How a bridge should be asked to think.
///
/// Modes exist as an abstraction from the start because Copilot's deeper research mode is a
/// different interaction with the same surface, not a different bridge.
public enum CopilotMode: String, Sendable, Codable, CaseIterable {
    /// A normal chat turn.
    case standard
    /// Copilot's longer-running research mode.
    ///
    /// - Note: Whether this can be driven reliably depends on the Copilot build in front of us.
    ///   `CopilotBridge` detects the affordance and reports honestly when it is absent rather than
    ///   pretending a standard answer is a researched one. See `docs/ARCHITECTURE.md`.
    case researcher
}

/// Everything a bridge needs to know beyond the prompt itself.
public struct BridgeContext: Sendable, Equatable {
    /// Desktop information the user has agreed to share with the bridge.
    ///
    /// This is deliberately plain text, not a screenshot: the handoff should be inspectable by the
    /// user before it leaves the machine.
    public let sharedContext: String?
    /// How long to wait for a response before giving up.
    public let timeout: Duration
    /// Which interaction mode to request.
    public let mode: CopilotMode

    public init(
        sharedContext: String? = nil,
        timeout: Duration = .seconds(120),
        mode: CopilotMode = .standard
    ) {
        self.sharedContext = sharedContext
        self.timeout = timeout
        self.mode = mode
    }
}

/// What a bridge produced.
public struct BridgeResult: Sendable, Equatable {
    /// The response text, extracted from the bridge's interface.
    public let text: String
    /// The mode that actually ran, which may differ from the one requested if the affordance for
    /// the requested mode could not be found.
    public let mode: CopilotMode
    /// Set when the bridge had to fall back, so the agent and the user both know the answer is not
    /// what was asked for.
    public let modeFallbackReason: String?

    public init(text: String, mode: CopilotMode = .standard, modeFallbackReason: String? = nil) {
        self.text = text
        self.mode = mode
        self.modeFallbackReason = modeFallbackReason
    }
}

/// A conversational AI application that AbleKit can consult mid-task.
public protocol AIBridge: Sendable {
    /// Which bridge this is.
    var identifier: AIBridgeIdentifier { get }

    /// Whether the backing application is installed and reachable right now.
    func isAvailable() async -> Bool

    /// Asks the bridge a question and waits for its answer.
    func ask(prompt: String, context: BridgeContext) async throws -> BridgeResult
}

/// Why a bridge interaction failed.
public enum AIBridgeError: Error, Equatable, Sendable {
    /// The application is not installed, or no window could be found.
    case unavailable(String)
    /// The prompt field could not be located in the interface.
    case promptFieldNotFound
    /// The response area could not be located.
    case responseNotFound
    /// The bridge did not settle on an answer within the allotted time.
    case timedOut(Duration)
    /// The user cancelled while the bridge was working.
    case cancelled
}

extension AIBridgeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unavailable(let detail): detail
        case .promptFieldNotFound: "Could not find where to type the prompt."
        case .responseNotFound: "Could not find the response."
        case .timedOut(let duration):
            "No response after \(Int(duration.components.seconds) )s."
        case .cancelled: "Cancelled."
        }
    }
}
