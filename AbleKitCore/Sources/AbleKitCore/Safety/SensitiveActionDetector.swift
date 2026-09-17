import Foundation

/// Decides how consequential a proposed action is.
///
/// Two things make an action weighty: what it does, and what it does it *to*. Pressing a button is
/// routine; pressing a button labelled "Delete Account" is not. Because AbleKit prefers semantic
/// targets, the label is usually available — which is a second, quieter argument for the
/// Accessibility-first design.
///
/// This detector is deliberately conservative. A false "please confirm" costs the user one
/// keystroke; a false "go ahead" can cost them an email they cannot unsend.
public struct SensitiveActionDetector: Sendable {

    public init() {}

    /// Words that mean an action leaves the machine or cannot be taken back.
    ///
    /// Matched against element labels as whole words, so that "Send" is caught but "Sender" in a
    /// column heading is not.
    static let consequentialKeywords: Set<String> = [
        "send", "submit", "post", "publish", "share", "reply", "forward",
        "delete", "remove", "erase", "destroy", "trash", "discard", "clear",
        "buy", "purchase", "pay", "order", "checkout", "subscribe", "transfer",
        "install", "uninstall", "update", "upgrade", "restart", "shutdown", "reset",
        "confirm", "apply", "accept", "agree", "authorize", "approve", "grant",
        "deactivate", "disable", "revoke", "unsubscribe", "cancel",
        "quit", "empty trash", "log out", "move to trash",
    ]

    /// Words that mean AbleKit should not act autonomously at all.
    static let restrictedKeywords: Set<String> = [
        "password", "passcode", "passphrase", "credential", "credentials",
        "ssn", "social security", "credit card", "card number", "cvv", "security code",
        "wire", "withdraw", "sign in", "log in", "login", "sign up",
    ]

    /// Accessibility roles that always hold a secret.
    static let secureRoles: Set<String> = ["AXSecureTextField"]

    /// Classifies an action in the context it will run in.
    public func classify(_ action: DesktopAction, context: DesktopContext? = nil) -> ClassificationResult {
        switch action {
        case .typeText(let text, let field):
            return classifyTyping(text, into: field, context: context)

        case .click(let target), .doubleClick(let target):
            return classifyTarget(target)

        case .accessibilityAction(let element, let axAction):
            // A menu-opening or selection action is not itself consequential; pressing is.
            guard axAction == "AXPress" || axAction == "AXConfirm" || axAction == "AXPick" else {
                return .routine
            }
            return classifyTarget(.element(element))

        case .chooseMenuItem(let path):
            // A menu command is judged by its own title, the same way a button is judged by its
            // label: File › New is routine, File › Delete is not.
            guard let title = path.last else { return .routine }
            return classifyLabel(title)

        case .pressKey(let key):
            // Return in a dialog is how most confirmations are accepted.
            if case .returnKey = key, hasModalDialog(context) {
                return ClassificationResult(
                    .consequential,
                    reason: "This confirms the dialog that is open."
                )
            }
            return .routine

        case .hotkey(let key, let modifiers):
            return classifyHotkey(key: key, modifiers: modifiers)

        case .nativeAction(let operation):
            return classifyNative(operation)

        case .askAIBridge:
            // Sending desktop information to another application is a real disclosure, so the
            // handoff is always shown to the user before it happens.
            return ClassificationResult(
                .consequential,
                reason: "This sends information to another application."
            )

        case .rightClick, .movePointer, .scroll, .drag, .wait, .readScreen, .openApplication,
            .activateApplication, .requestConfirmation, .requestUserInput, .complete, .fail:
            return .routine
        }
    }

    // MARK: - Individual judgements

    private func classifyTyping(_ text: String, into field: ElementReference?, context: DesktopContext?)
        -> ClassificationResult
    {
        // The field the text will land in: the one named, or else whatever has focus.
        let destination = field ?? context?.accessibility?.elements.first(where: \.isFocused)

        // Typing into a secure field means we are filling in a credential, which AbleKit does not do.
        if let destination, Self.secureRoles.contains(destination.role) {
            return ClassificationResult(
                .restricted,
                reason: "AbleKit does not type into password fields."
            )
        }
        if let matched = Self.matchedKeyword(in: text, from: Self.restrictedKeywords) {
            return ClassificationResult(
                .restricted,
                reason: "This text looks like it contains sensitive information (\(matched))."
            )
        }
        // A field labelled as a password or card number is sensitive even if it is not a secure field.
        if let label = destination?.bestLabel,
            let matched = Self.matchedKeyword(in: label, from: Self.restrictedKeywords)
        {
            return ClassificationResult(
                .restricted,
                reason: "\u{201C}\(label)\u{201D} asks for credentials or payment details (\(matched))."
            )
        }
        return .routine
    }

    private func classifyTarget(_ target: PointerTarget) -> ClassificationResult {
        guard case .element(let element) = target else {
            // A bare coordinate carries no label, so there is nothing to judge it by. This is one
            // more reason the agent is pushed toward semantic targets wherever they exist.
            return .routine
        }
        if Self.secureRoles.contains(element.role) {
            return ClassificationResult(
                .restricted,
                reason: "This is a password field."
            )
        }
        guard let label = element.bestLabel else { return .routine }
        return classifyLabel(label)
    }

    private func classifyLabel(_ label: String) -> ClassificationResult {
        if let matched = Self.matchedKeyword(in: label, from: Self.restrictedKeywords) {
            return ClassificationResult(
                .restricted,
                reason: "\u{201C}\(label)\u{201D} involves credentials or payment (\(matched))."
            )
        }
        if let matched = Self.matchedKeyword(in: label, from: Self.consequentialKeywords) {
            return ClassificationResult(
                .consequential,
                reason: "\u{201C}\(label)\u{201D} looks like it \(matched)s something."
            )
        }
        return .routine
    }

    private func classifyHotkey(key: Key, modifiers: [ModifierKey]) -> ClassificationResult {
        let modifierSet = Set(modifiers)
        guard case .character(let character) = key else {
            if case .delete = key, modifierSet.contains(.command) {
                return ClassificationResult(.consequential, reason: "This deletes something.")
            }
            return .routine
        }
        switch (character.lowercased(), modifierSet) {
        case ("q", [.command]):
            return ClassificationResult(.consequential, reason: "This quits the application.")
        case ("w", [.command]) where modifierSet.contains(.option):
            return ClassificationResult(.consequential, reason: "This closes every window.")
        case ("d", [.command, .shift]), ("\u{21A9}", [.command]):
            return ClassificationResult(.consequential, reason: "This sends the message.")
        default:
            return .routine
        }
    }

    private func classifyNative(_ operation: NativeOperation) -> ClassificationResult {
        switch operation {
        case .revealInFinder, .openSystemSettings, .setClipboard:
            return .routine
        case .openURL(let string):
            // A file:// or custom-scheme URL can launch something; http(s) just opens a page.
            guard let scheme = URL(string: string)?.scheme?.lowercased() else { return .routine }
            if scheme == "http" || scheme == "https" { return .routine }
            return ClassificationResult(
                .consequential,
                reason: "This opens a \(scheme): link, which can start another application."
            )
        }
    }

    private func hasModalDialog(_ context: DesktopContext?) -> Bool {
        context?.accessibility?.elements.contains { $0.role == "AXSheet" || $0.subrole == "AXDialog" }
            ?? false
    }

    // MARK: - Matching

    /// Finds the first keyword that appears in `text` as a whole word.
    ///
    /// Whole-word matching keeps "Resend" and "Undelete" from tripping the "send"/"delete" rules
    /// while still catching "Send Now" and "Delete All".
    static func matchedKeyword(in text: String, from keywords: Set<String>) -> String? {
        let lowered = text.lowercased()
        // Multi-word keywords ("credit card") cannot be found by token comparison.
        for keyword in keywords where keyword.contains(" ") {
            if lowered.contains(keyword) { return keyword }
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for token in tokens where keywords.contains(token) {
            return token
        }
        return nil
    }
}
