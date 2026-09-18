import CoreGraphics
import Foundation

/// A semantic handle to a single user-interface element, captured from the Accessibility tree.
///
/// This is the currency of AbleKit's preferred interaction path. Rather than "click (673, 482)",
/// the agent works with "the enabled `AXButton` titled *Save*, which supports `AXPress`" — a
/// description that stays true when the window moves and that can be re-resolved after the
/// interface changes.
public struct ElementReference: Sendable, Equatable, Codable, Identifiable {
    /// A short identifier assigned when the snapshot was taken — `e1`, `e2`, … in walk order.
    ///
    /// Short on purpose: the planner has to copy it back exactly, and a small model copying
    /// `e0-12-3-1-4-2` gets it wrong often enough to matter. Stable only within one snapshot.
    public let id: String
    /// Where the element sits in the tree, as child indexes from the window (`0-12-3-1`), used to
    /// find the live element again at execution time. Separate from `id` so the planner never
    /// has to handle it.
    public let treePath: String?
    /// The Accessibility role, e.g. `AXButton`.
    public let role: String
    /// A more specific subrole where the app provides one, e.g. `AXCloseButton`.
    public let subrole: String?
    /// The element's title, e.g. the text on a button.
    public let title: String?
    /// The element's current value, e.g. the contents of a text field or a checkbox's state.
    public let value: String?
    /// The developer-facing description (`AXDescription`), often the only label on an icon button.
    public let elementDescription: String?
    /// The app-assigned identifier (`AXIdentifier`), the most stable label when it exists.
    public let identifier: String?
    /// The element's frame in canonical space (global, top-left origin, points).
    public let frame: CGRect
    /// Whether the element is currently enabled.
    public let isEnabled: Bool
    /// Whether the element currently has keyboard focus.
    public let isFocused: Bool
    /// The Accessibility actions the element advertises, e.g. `["AXPress"]`.
    public let actions: [String]
    /// Identifier of this element's parent within the same snapshot, if any.
    public let parentID: String?

    public init(
        id: String,
        treePath: String? = nil,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        elementDescription: String? = nil,
        identifier: String? = nil,
        frame: CGRect,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        actions: [String] = [],
        parentID: String? = nil
    ) {
        self.id = id
        self.treePath = treePath
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.elementDescription = elementDescription
        self.identifier = identifier
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
        self.parentID = parentID
    }

    /// The best human-readable name for this element, preferring the most specific label available.
    public var bestLabel: String? {
        for candidate in [title, elementDescription, identifier, value] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    /// Whether the element advertises `AXPress`, the action that activates most controls.
    public var isPressable: Bool {
        actions.contains("AXPress")
    }

    /// Whether the element can accept typed text.
    public var isTextInput: Bool {
        role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
            || subrole == "AXSearchField"
    }

    /// Whether this element is worth showing to the planner at all.
    ///
    /// Accessibility trees are mostly structure: groups, layout containers, and decorative images
    /// that no one can interact with. Feeding those to the model wastes its limited context and
    /// makes the genuinely actionable elements harder to find.
    public var isInteresting: Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        // A text field needs no name: it is identified by being the field.
        if isTextInput { return true }
        // Everything else must have a name. An unnamed control cannot be described to the planner,
        // so choosing it is guesswork — and the planner did guess, pressing "untitled" buttons in
        // Calculator while the numbered ones sat in the list.
        guard bestLabel != nil else { return false }
        if !actions.isEmpty { return true }
        return Self.interestingRoles.contains(role)
    }

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXSlider",
        "AXStaticText", "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXStepper",
        "AXSegmentedControl", "AXToolbar", "AXWindow", "AXSheet", "AXOutline", "AXTable",
    ]
}

extension ElementReference: CustomStringConvertible {
    public var description: String {
        let name = bestLabel.map { "\u{201C}\($0.truncated(to: 40))\u{201D}" } ?? "untitled"
        return "\(role.friendlyRoleName) \(name)"
    }
}

extension String {
    /// Turns `AXPopUpButton` into `pop up button` for user-facing text.
    var friendlyRoleName: String {
        let stripped = hasPrefix("AX") ? String(dropFirst(2)) : self
        var words: [String] = []
        var current = ""
        for character in stripped {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }
}
