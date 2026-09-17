import Foundation

/// What to gather when collecting context.
///
/// Collecting everything on every step would be wasteful and, in the case of screen capture,
/// visibly so — the screen-recording indicator would sit lit for the whole task. Steps ask for
/// what they need.
public struct ContextCollectionOptions: Sendable, Equatable {
    /// Read the frontmost app's Accessibility tree.
    public var includesAccessibility: Bool
    /// Capture the screen.
    public var includesScreenshot: Bool
    /// Run OCR over the capture. Implies `includesScreenshot`.
    public var includesScreenText: Bool
    /// Read the current selection and the clipboard.
    public var includesUserContent: Bool
    /// Read the application's menu bar. Skipped for verification, which only needs to see what
    /// changed in the window.
    public var includesMenus: Bool
    /// Cap on Accessibility elements, to bound both the work and the prompt.
    public var maximumElements: Int
    /// How deep to walk the Accessibility tree.
    public var maximumDepth: Int

    public init(
        includesAccessibility: Bool = true,
        includesScreenshot: Bool = false,
        includesScreenText: Bool = false,
        includesUserContent: Bool = true,
        includesMenus: Bool = true,
        maximumElements: Int = 300,
        maximumDepth: Int = 12
    ) {
        self.includesAccessibility = includesAccessibility
        self.includesScreenshot = includesScreenshot
        self.includesScreenText = includesScreenText || includesScreenshot && includesScreenText
        self.includesUserContent = includesUserContent
        self.includesMenus = includesMenus
        self.maximumElements = maximumElements
        self.maximumDepth = maximumDepth
    }

    /// Everything, used when the user first invokes AbleKit and when an app turns out to expose
    /// nothing semantic.
    public static let full = ContextCollectionOptions(
        includesAccessibility: true,
        includesScreenshot: true,
        includesScreenText: true,
        includesUserContent: true
    )

    /// Semantic information only. The default between steps: fast, and it leaves the screen-
    /// recording indicator alone.
    public static let semantic = ContextCollectionOptions(
        includesAccessibility: true,
        includesScreenshot: false,
        includesScreenText: false,
        includesUserContent: true
    )

    /// The cheapest useful snapshot, for verifying what just happened.
    public static let lightweight = ContextCollectionOptions(
        includesAccessibility: true,
        includesScreenshot: false,
        includesScreenText: false,
        includesUserContent: false,
        includesMenus: false,
        maximumElements: 120,
        maximumDepth: 8
    )
}

/// Gathers the desktop context.
///
/// Behind a protocol so the agent loop can be driven from scripted desktops in tests, with no
/// screen capture, no permissions, and no real applications.
public protocol ContextCollecting: Sendable {
    func collect(options: ContextCollectionOptions) async -> DesktopContext
}
