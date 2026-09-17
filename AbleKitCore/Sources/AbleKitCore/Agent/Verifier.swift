import Foundation

/// Decides whether an action actually did anything.
///
/// The brief's seventh principle is "never assume an action succeeded", and its first is "prefer
/// deterministic automation over AI". Both apply here at once, so verification is a ladder:
///
/// 1. **Ask the system.** Some actions have an unambiguous observable consequence — after
///    activating an app, either it is frontmost or it is not. No model is needed or wanted.
/// 2. **Ask the screen.** If nothing observable changed at all, that is strong evidence on its own.
/// 3. **Ask the model**, but only for the genuinely ambiguous remainder.
///
/// Most steps in a real task are settled at rung one, which makes verification nearly free and,
/// more importantly, correct.
public struct Verifier: Sendable {
    private let intelligence: any IntelligenceProvider

    public init(intelligence: any IntelligenceProvider) {
        self.intelligence = intelligence
    }

    public func verify(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) async -> VerificationResult {
        if let deterministic = Self.deterministicVerdict(action: action, before: before, after: after) {
            return deterministic
        }

        do {
            let judgement = try await intelligence.verify(action: action, before: before, after: after)
            // The model is the least reliable judge on the ladder. In the first live evaluation it
            // watched File › New Folder create a folder and called that a failure, and three such
            // verdicts end a task. A "failed" from the model when the screen visibly changed is
            // therefore treated as unsettled: the planner still reads the model's reason and can
            // react to it, but the task is not ended on the model's say-so. "Nothing changed" is
            // still a hard failure — that one was decided above, from the system, not the model.
            if judgement.outcome == .failed, before.stateFingerprint != after.stateFingerprint {
                return .inconclusive("Something changed, but perhaps not as intended: \(judgement.reason)")
            }
            return judgement
        } catch {
            // A verification that cannot be performed is reported as exactly that. Treating a
            // failed check as a success is the one outcome that must never happen here.
            return .inconclusive("AbleKit could not check the result: \(error.localizedDescription)")
        }
    }

    /// Verdicts that can be reached by looking at the system rather than by reasoning about it.
    ///
    /// Returns `nil` when the action has no unambiguous signature, which hands the question up the
    /// ladder.
    static func deterministicVerdict(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) -> VerificationResult? {
        switch action {
        case .openApplication(let app), .activateApplication(let app):
            guard let frontmost = after.frontmostApplication else {
                return .failed("No application came forward.", shouldRetry: true)
            }
            if Self.matches(frontmost, app) {
                return .succeeded("\(frontmost.localizedName) is now frontmost.")
            }
            return .failed(
                "\(frontmost.localizedName) is frontmost, not \(app.displayName).",
                shouldRetry: true
            )

        case .wait:
            return .succeeded("Waited.")

        case .readScreen:
            return .succeeded("The screen will be read on the next look.")

        case .complete, .fail, .requestConfirmation, .requestUserInput:
            return .succeeded("No desktop change was expected.")

        case .nativeAction(.setClipboard(let text)):
            return after.clipboard?.text == text
                ? .succeeded("The clipboard now holds the text.")
                : .failed("The clipboard was not updated.")

        case .askAIBridge:
            // The bridge capability only reports success when it extracted an answer, so there is
            // nothing further for the screen to tell us.
            return .succeeded("The bridge returned an answer.")

        case .typeText(let text, let field):
            // If the field now contains what was typed, that settles it. The named field is found
            // again by role and label, since its id belongs to the earlier snapshot. If the text is
            // not visible, it may have gone somewhere legitimate that cannot be read, so defer.
            let candidates: [ElementReference?] = [
                field.flatMap { field in
                    after.accessibility?.elements.first {
                        $0.role == field.role && $0.bestLabel == field.bestLabel
                    }
                },
                after.accessibility?.elements.first(where: \.isFocused),
            ]
            for case let element? in candidates {
                if let value = element.value, value.contains(text) {
                    return .succeeded("The text appears in \(element.description).")
                }
            }
            return nil

        case .movePointer:
            return .succeeded("The pointer moved.")

        default:
            break
        }

        // Nothing at all changed. For an action meant to change something, that is a failure —
        // and saying so cheaply here saves a model call on the most common failure mode there is.
        if before.stateFingerprint == after.stateFingerprint, Self.expectsVisibleChange(action) {
            return .failed("Nothing on screen changed.", shouldRetry: true)
        }

        return nil
    }

    /// Whether an action ought to leave a visible trace.
    ///
    /// Scrolling is the notable exception: scrolling a view that is already at the end changes
    /// nothing and has still done the only thing it could do.
    private static func expectsVisibleChange(_ action: DesktopAction) -> Bool {
        switch action {
        case .scroll, .movePointer, .wait:
            false
        default:
            true
        }
    }

    private static func matches(_ running: RunningApplicationInfo, _ reference: ApplicationReference)
        -> Bool
    {
        if let bundle = reference.bundleIdentifier, !bundle.isEmpty {
            return running.bundleIdentifier?.caseInsensitiveCompare(bundle) == .orderedSame
        }
        // A name the locator knows is compared by bundle identifier, because names drift: the
        // planner still says "System Preferences" for an app that has been called System Settings
        // for years, and comparing names reported a correct launch as the wrong app.
        if let name = reference.name?.lowercased().trimmed,
            let bundle = ApplicationLocator.knownBundleIdentifiers[name],
            let runningBundle = running.bundleIdentifier
        {
            return runningBundle.caseInsensitiveCompare(bundle) == .orderedSame
        }
        if let name = reference.name, !name.isEmpty {
            // Matching loosely on both sides: the user says "Safari", the system may report
            // "Safari" or a longer localised name, and a planner may say "System Settings" for
            // an app whose bundle name differs.
            let runningName = running.localizedName.lowercased()
            let wanted = name.lowercased()
            return runningName == wanted || runningName.contains(wanted) || wanted.contains(runningName)
        }
        return false
    }
}
