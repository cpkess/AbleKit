import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and operates application interfaces through the Accessibility APIs.
///
/// This is AbleKit's most important capability. An Accessibility tree gives the agent what a
/// screenshot cannot: names, roles, states, and the specific actions a control supports. Acting on
/// that is both more reliable than aiming at coordinates and more inspectable afterwards — "pressed
/// the button named Save" is a claim that can be checked.
///
/// ## Threading
///
/// `AXUIElement` is a CoreFoundation type that is not `Sendable`, and every call into it is a
/// synchronous IPC round trip to the target application. Element handles are therefore created,
/// used, and discarded entirely inside one synchronous function and never cross an isolation
/// boundary; callers get plain value types back. Calls are made with a short messaging timeout so
/// that an unresponsive application stalls one step rather than the whole agent.
public struct AccessibilityService: Sendable {

    /// How long to wait for an application to answer before giving up on an attribute.
    ///
    /// Deliberately short. A hung app is common, and the agent's own timing budget matters more
    /// than completing a tree walk.
    public static let messagingTimeout: Float = 2.0

    public init() {}

    // MARK: - Reading

    /// Walks the frontmost window of an application and returns a flattened snapshot.
    ///
    /// - Parameters:
    ///   - processIdentifier: The application to read.
    ///   - bundleIdentifier: Recorded on the snapshot for the planner's benefit.
    ///   - maximumElements: Stops the walk once this many elements have been collected.
    ///   - maximumDepth: Stops descending past this depth.
    public func snapshot(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        maximumElements: Int = 300,
        maximumDepth: Int = 12,
        includesMenus: Bool = true
    ) -> AccessibilitySnapshot {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)

        // Prefer the focused window: the rest of the application's windows are not what the user
        // is looking at, and walking them wastes the element budget.
        let root =
            Self.copyElement(application, kAXFocusedWindowAttribute)
            ?? Self.copyElement(application, kAXMainWindowAttribute)
            ?? application

        var elements: [ElementReference] = []
        var truncated = false
        let focusedElement = Self.copyElement(application, kAXFocusedUIElementAttribute)

        Self.walk(
            root,
            path: [],
            parentID: nil,
            depth: 0,
            maximumDepth: maximumDepth,
            maximumElements: maximumElements,
            focused: focusedElement,
            into: &elements,
            truncated: &truncated
        )

        return AccessibilitySnapshot(
            bundleIdentifier: bundleIdentifier,
            elements: elements,
            wasTruncated: truncated,
            menuItems: includesMenus ? Self.menuItems(of: application) : []
        )
    }

    // MARK: - Menus

    /// How many commands to read from the menu bar. Enough for any ordinary app, bounded so that an
    /// IDE's several hundred commands cannot swamp the prompt or stall a step.
    static let maximumMenuItems = 250

    /// Reads the application's menu bar into a flat list of commands.
    ///
    /// The Apple menu is skipped: it belongs to the system, not the app, and choosing from it is
    /// never what a task about the app means. Separators, and the dynamic items macOS adds to
    /// every app (Services, and the like), are left out too.
    static func menuItems(of application: AXUIElement) -> [MenuItem] {
        guard let menuBar = copyElement(application, kAXMenuBarAttribute) else { return [] }
        var items: [MenuItem] = []
        for barItem in children(of: menuBar).dropFirst() {
            guard let title = copyString(barItem, kAXTitleAttribute) else { continue }
            for menu in children(of: barItem) {
                collectMenuItems(menu, path: [title], depth: 0, into: &items)
            }
            if items.count >= maximumMenuItems { break }
        }
        return Array(items.prefix(maximumMenuItems))
    }

    private static let ignoredMenuTitles: Set<String> = ["Services"]

    private static func collectMenuItems(
        _ menu: AXUIElement,
        path: [String],
        depth: Int,
        into items: inout [MenuItem]
    ) {
        guard depth < 3, items.count < maximumMenuItems else { return }
        for item in children(of: menu) {
            guard let title = copyString(item, kAXTitleAttribute),
                !ignoredMenuTitles.contains(title)
            else { continue }
            let itemPath = path + [title]
            let submenus = children(of: item)
            if submenus.isEmpty {
                items.append(
                    MenuItem(
                        path: itemPath,
                        isEnabled: copyBool(item, kAXEnabledAttribute) ?? true,
                        shortcut: shortcut(of: item)
                    )
                )
            } else {
                for submenu in submenus {
                    collectMenuItems(submenu, path: itemPath, depth: depth + 1, into: &items)
                }
            }
        }
    }

    /// The shortcut shown beside a menu item, rendered the way the menu shows it (`⇧⌘S`).
    private static func shortcut(of item: AXUIElement) -> String? {
        guard let character = copyString(item, "AXMenuItemCmdChar") else { return nil }
        var value: CFTypeRef?
        var modifiers = 0
        if AXUIElementCopyAttributeValue(item, "AXMenuItemCmdModifiers" as CFString, &value) == .success,
            let number = value as? Int
        {
            modifiers = number
        }
        // AXMenuItemCmdModifiers: bit 0 shift, bit 1 option, bit 2 control, bit 3 means NO command.
        var symbols = ""
        if modifiers & 4 != 0 { symbols += "\u{2303}" }
        if modifiers & 2 != 0 { symbols += "\u{2325}" }
        if modifiers & 1 != 0 { symbols += "\u{21E7}" }
        if modifiers & 8 == 0 { symbols += "\u{2318}" }
        return symbols + character
    }

    /// Chooses a menu command by its titles, without opening the menu.
    ///
    /// `AXPress` on a menu item runs its command directly, exactly as if it had been chosen, so no
    /// menu flashes open and nothing depends on where the menu bar is drawn.
    public func chooseMenuItem(_ path: [String], processIdentifier: pid_t) throws(CapabilityError) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let menuBar = Self.copyElement(application, kAXMenuBarAttribute) else {
            throw .executionFailed("This app has no menu bar AbleKit can read.")
        }
        guard !path.isEmpty else { throw .executionFailed("No menu command was named.") }

        var current: AXUIElement = menuBar
        for (depth, title) in path.enumerated() {
            let wanted = AccessibilitySnapshot.normalizeMenuTitle(title)
            // Below the menu bar, each item's children are a single AXMenu holding the entries.
            let candidates = depth == 0
                ? Self.children(of: current)
                : Self.children(of: current).flatMap { Self.children(of: $0) }
            guard
                let match = candidates.first(where: { candidate in
                    guard let candidateTitle = Self.copyString(candidate, kAXTitleAttribute) else {
                        return false
                    }
                    return AccessibilitySnapshot.normalizeMenuTitle(candidateTitle) == wanted
                })
            else {
                let shown = path.prefix(depth + 1).joined(separator: " \u{203A} ")
                throw .executionFailed("There is no menu command \u{201C}\(shown)\u{201D}.")
            }
            current = match
        }

        if Self.copyBool(current, kAXEnabledAttribute) == false {
            throw .executionFailed(
                "\u{201C}\(path.joined(separator: " \u{203A} "))\u{201D} is not available right now."
            )
        }
        let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
        guard result == .success else {
            throw .executionFailed(
                "\u{201C}\(path.joined(separator: " \u{203A} "))\u{201D} could not be chosen (\(Self.describe(result)))."
            )
        }
    }

    /// The text currently selected in the frontmost application, if it exposes any.
    public func selectedText(processIdentifier: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let focused = Self.copyElement(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        let selection = Self.copyString(focused, kAXSelectedTextAttribute)
        guard let selection, !selection.isEmpty else { return nil }
        return selection
    }

    /// File URLs of the items currently selected in an application that exposes them.
    ///
    /// Finder publishes an `AXURL` on selected items, so the paths can be read with the
    /// Accessibility permission AbleKit already holds. Applications that do not publish it simply
    /// return nothing — AbleKit does not fall back to Apple Events, because a third permission
    /// prompt is a poor trade for one context field.
    public func selectedFileURLs(processIdentifier: pid_t, limit: Int = 20) -> [String] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard
            let window = Self.copyElement(application, kAXFocusedWindowAttribute)
                ?? Self.copyElement(application, kAXMainWindowAttribute)
        else { return [] }

        var urls: [String] = []
        Self.collectSelectedURLs(window, depth: 0, limit: limit, into: &urls)
        return urls
    }

    private static func collectSelectedURLs(
        _ element: AXUIElement,
        depth: Int,
        limit: Int,
        into urls: inout [String]
    ) {
        guard urls.count < limit, depth < 12 else { return }

        if copyBool(element, kAXSelectedAttribute) == true,
            let url = copyURL(element, "AXURL"), url.isFileURL
        {
            urls.append(url.path)
        }
        for child in children(of: element) {
            collectSelectedURLs(child, depth: depth + 1, limit: limit, into: &urls)
        }
    }

    private static func copyURL(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? URL
    }

    /// The frontmost window of an application, in canonical screen coordinates.
    public func focusedWindow(processIdentifier: pid_t, applicationName: String?, bundleIdentifier: String?)
        -> WindowInfo?
    {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard
            let window = Self.copyElement(application, kAXFocusedWindowAttribute)
                ?? Self.copyElement(application, kAXMainWindowAttribute)
        else { return nil }

        return WindowInfo(
            title: Self.copyString(window, kAXTitleAttribute),
            owningApplication: applicationName,
            owningBundleIdentifier: bundleIdentifier,
            frame: Self.frame(of: window) ?? .zero,
            isOnScreen: true,
            isFocused: true
        )
    }

    // MARK: - Acting

    /// Performs an Accessibility action on the element a reference names.
    ///
    /// The reference is re-resolved against the live tree first, because the snapshot it came from
    /// may be several hundred milliseconds old — long enough for a sheet to have opened.
    public func perform(
        _ action: String,
        on reference: ElementReference,
        processIdentifier: pid_t
    ) throws(CapabilityError) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)

        guard let element = Self.resolve(reference, in: application) else {
            throw .executionFailed("\(reference.description) is no longer on screen.")
        }

        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw .executionFailed(
                "\(reference.description) refused \(action) (\(Self.describe(result)))."
            )
        }
    }

    /// Gives an element keyboard focus, so that typed text goes to the right place.
    public func focus(_ reference: ElementReference, processIdentifier: pid_t) throws(CapabilityError) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)

        guard let element = Self.resolve(reference, in: application) else {
            throw .executionFailed("\(reference.description) is no longer on screen.")
        }
        let result = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        guard result == .success else {
            throw .executionFailed("\(reference.description) would not take focus.")
        }
    }

    /// Whether AbleKit is trusted to use the Accessibility APIs at all.
    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Walking

    /// Depth-first walk, collecting every element into a flat list.
    ///
    /// Flat rather than nested because everything downstream — prompt building, matching, the
    /// debug interface — wants a list, and parentage is preserved by `parentID` for the rare case
    /// that needs it.
    private static func walk(
        _ element: AXUIElement,
        path: [Int],
        parentID: String?,
        depth: Int,
        maximumDepth: Int,
        maximumElements: Int,
        focused: AXUIElement?,
        into elements: inout [ElementReference],
        truncated: inout Bool
    ) {
        guard elements.count < maximumElements else {
            truncated = true
            return
        }
        guard let role = copyString(element, kAXRoleAttribute) else { return }

        let identifier = "e\(elements.count + 1)"
        let reference = ElementReference(
            id: identifier,
            treePath: Self.treePath(for: path),
            role: role,
            subrole: copyString(element, kAXSubroleAttribute),
            title: copyString(element, kAXTitleAttribute),
            value: copyValueDescription(element),
            elementDescription: copyString(element, kAXDescriptionAttribute),
            identifier: copyString(element, kAXIdentifierAttribute),
            frame: frame(of: element) ?? .zero,
            isEnabled: copyBool(element, kAXEnabledAttribute) ?? true,
            isFocused: focused.map { CFEqual(element, $0) } ?? false,
            actions: actionNames(of: element),
            parentID: parentID
        )
        elements.append(reference)

        guard depth < maximumDepth else {
            // Only flag truncation if there was actually something below this point.
            if !children(of: element).isEmpty { truncated = true }
            return
        }

        for (index, child) in children(of: element).enumerated() {
            guard elements.count < maximumElements else {
                truncated = true
                return
            }
            walk(
                child,
                path: path + [index],
                parentID: identifier,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumElements: maximumElements,
                focused: focused,
                into: &elements,
                truncated: &truncated
            )
        }
    }

    /// An element's position in the tree, as the child indexes leading to it from the window.
    ///
    /// This is what makes a reference re-resolvable: given `0-3-1`, the live tree can be walked back
    /// down to the same place without holding onto a handle across a suspension point. The window
    /// itself is the empty path.
    static func treePath(for path: [Int]) -> String {
        path.map(String.init).joined(separator: "-")
    }

    static func path(fromTreePath treePath: String) -> [Int]? {
        guard !treePath.isEmpty else { return [] }
        let components = treePath.split(separator: "-").map { Int($0) }
        guard !components.contains(where: { $0 == nil }) else { return nil }
        return components.compactMap { $0 }
    }

    /// Finds the live element a reference names.
    ///
    /// Walking the recorded path is tried first and is almost always right. When the tree has
    /// shifted underneath us, the path may now lead somewhere else, so the result is checked
    /// against the role and label that were recorded — and if it does not match, the tree is
    /// searched for a control that does. That second pass is what lets a plan survive a window
    /// reflowing between the snapshot and the click.
    private static func resolve(_ reference: ElementReference, in application: AXUIElement)
        -> AXUIElement?
    {
        let root =
            copyElement(application, kAXFocusedWindowAttribute)
            ?? copyElement(application, kAXMainWindowAttribute)
            ?? application

        if let treePath = reference.treePath, let path = path(fromTreePath: treePath),
            let candidate = element(at: path, from: root),
            matches(candidate, reference)
        {
            return candidate
        }
        return search(root, for: reference, depth: 0)
    }

    private static func element(at path: [Int], from root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            let childElements = children(of: current)
            guard index < childElements.count else { return nil }
            current = childElements[index]
        }
        return current
    }

    private static func matches(_ element: AXUIElement, _ reference: ElementReference) -> Bool {
        guard copyString(element, kAXRoleAttribute) == reference.role else { return false }
        guard let expected = reference.bestLabel else { return true }
        let actual =
            copyString(element, kAXTitleAttribute)
            ?? copyString(element, kAXDescriptionAttribute)
            ?? copyString(element, kAXIdentifierAttribute)
        return actual == expected
    }

    /// Depth-first search for an element matching a reference's role and label.
    private static func search(_ element: AXUIElement, for reference: ElementReference, depth: Int)
        -> AXUIElement?
    {
        guard depth < 16 else { return nil }
        if matches(element, reference), reference.bestLabel != nil { return element }
        for child in children(of: element) {
            if let found = search(child, for: reference, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Attribute helpers

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let array = value as? [AXUIElement]
        else { return [] }
        return array
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let result = value, CFGetTypeID(result) == AXUIElementGetTypeID()
        else { return nil }
        return (result as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let string = value as? String, !string.isEmpty
        else { return nil }
        return string
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    /// An element's value, rendered as text.
    ///
    /// Values come back as strings, numbers, or booleans depending on the control, and the planner
    /// only ever reads them, so they are normalised to text here. A checkbox reads as "checked"
    /// rather than "1", because that is what the model can reason about.
    private static func copyValueDescription(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let result = value
        else { return nil }

        if let string = result as? String { return string.isEmpty ? nil : string }
        if let number = result as? NSNumber {
            // Toggles report 0/1; describing them as text is what makes "is it on?" answerable.
            if CFGetTypeID(result) == CFBooleanGetTypeID() {
                return number.boolValue ? "checked" : "unchecked"
            }
            return number.stringValue
        }
        return nil
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
            let array = names as? [String]
        else { return [] }
        return array
    }

    /// An element's frame in canonical space.
    ///
    /// The Accessibility APIs already report global coordinates with a top-left origin, which is
    /// exactly AbleKit's canonical space — so there is nothing to convert here, and that is worth
    /// saying out loud because the AppKit half of the app uses the opposite convention.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: "succeeded"
        case .actionUnsupported: "the action is not supported"
        case .cannotComplete: "the app did not respond"
        case .notImplemented: "the app does not implement Accessibility for this"
        case .invalidUIElement: "the control no longer exists"
        case .apiDisabled: "Accessibility permission is not granted"
        default: "error \(error.rawValue)"
        }
    }
}
