import Foundation

/// A question AbleKit needs the user to answer before it can go on.
public struct UserPrompt: Sendable, Equatable, Identifiable {
    public enum Style: Sendable, Equatable {
        /// A yes/no confirmation before a consequential action.
        case confirmation(action: DesktopAction, reason: String)
        /// A free-text answer the agent needs.
        case input
    }

    public let id: UUID
    public let message: String
    public let style: Style

    public init(id: UUID = UUID(), message: String, style: Style) {
        self.id = id
        self.message = message
        self.style = style
    }
}

/// How the agent reaches the user mid-task.
///
/// Confirmation is requested *immediately before* the consequential step, not batched up front
/// (brief §18): the user is shown the actual thing about to happen, with the screen in the state
/// it will happen to.
public protocol UserInteracting: Sendable {
    /// Asks the user to approve an action. Returns `false` if they decline or dismiss.
    func confirm(_ prompt: UserPrompt) async -> Bool
    /// Asks the user for text. Returns `nil` if they dismiss without answering.
    func requestInput(_ prompt: UserPrompt) async -> String?
}

/// Declines everything, for tests and for headless runs where nobody is watching.
public struct DecliningUserInteraction: UserInteracting {
    public init() {}
    public func confirm(_ prompt: UserPrompt) async -> Bool { false }
    public func requestInput(_ prompt: UserPrompt) async -> String? { nil }
}
