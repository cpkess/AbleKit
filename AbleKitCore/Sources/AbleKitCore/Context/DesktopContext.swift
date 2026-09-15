import CoreGraphics
import Foundation

/// A running application, as far as AbleKit needs to know about it.
public struct RunningApplicationInfo: Sendable, Equatable, Codable {
    public let bundleIdentifier: String?
    public let localizedName: String
    public let processIdentifier: Int32
    public let isActive: Bool

    public init(
        bundleIdentifier: String?,
        localizedName: String,
        processIdentifier: Int32,
        isActive: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
        self.isActive = isActive
    }

    public var reference: ApplicationReference {
        ApplicationReference(bundleIdentifier: bundleIdentifier, name: localizedName)
    }
}

/// A window on screen.
public struct WindowInfo: Sendable, Equatable, Codable {
    public let windowID: UInt32?
    public let title: String?
    public let owningApplication: String?
    public let owningBundleIdentifier: String?
    /// The window's frame in canonical space (global, top-left origin, points).
    public let frame: CGRect
    public let isOnScreen: Bool
    public let isFocused: Bool

    public init(
        windowID: UInt32? = nil,
        title: String? = nil,
        owningApplication: String? = nil,
        owningBundleIdentifier: String? = nil,
        frame: CGRect,
        isOnScreen: Bool = true,
        isFocused: Bool = false
    ) {
        self.windowID = windowID
        self.title = title
        self.owningApplication = owningApplication
        self.owningBundleIdentifier = owningBundleIdentifier
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.isFocused = isFocused
    }
}

/// What the clipboard held when context was collected.
public struct ClipboardSnapshot: Sendable, Equatable, Codable {
    public let text: String?
    public let hasImage: Bool

    public init(text: String?, hasImage: Bool = false) {
        self.text = text
        self.hasImage = hasImage
    }
}

/// A run of text found on screen by Vision's OCR, placed back into canonical space.
public struct RecognizedText: Sendable, Equatable, Codable {
    public let string: String
    public let confidence: Float
    /// Where the text sits in canonical space (global, top-left origin, points).
    public let frame: CGRect

    public init(string: String, confidence: Float, frame: CGRect) {
        self.string = string
        self.confidence = confidence
        self.frame = frame
    }
}

/// What AbleKit saw on screen.
///
/// The `image` is deliberately **not** `Codable` and is never written to disk: it lives only as
/// long as the step that needs it. What survives a step is the derived, far smaller `textRegions`.
public struct ScreenObservation: Sendable {
    /// The captured frame. Ephemeral — held in memory for the duration of a step only.
    public let image: CGImage?
    /// How to map between this image and the screen.
    public let geometry: CaptureGeometry
    /// Text recognised in the image, already converted to canonical screen coordinates.
    public let textRegions: [RecognizedText]

    public init(image: CGImage?, geometry: CaptureGeometry, textRegions: [RecognizedText] = []) {
        self.image = image
        self.geometry = geometry
        self.textRegions = textRegions
    }

    /// All recognised text, reading roughly top-to-bottom then left-to-right.
    public var readableText: String {
        textRegions
            .sorted { lhs, rhs in
                // Treat lines within ~6pt of each other as the same row so that a row of buttons
                // reads left-to-right rather than being interleaved by sub-pixel y differences.
                if abs(lhs.frame.minY - rhs.frame.minY) > 6 { return lhs.frame.minY < rhs.frame.minY }
                return lhs.frame.minX < rhs.frame.minX
            }
            .map(\.string)
            .joined(separator: "\n")
    }
}

/// A flattened slice of an application's Accessibility tree.
public struct AccessibilitySnapshot: Sendable, Equatable, Codable {
    /// Bundle identifier of the application the snapshot was taken from.
    public let bundleIdentifier: String?
    /// Every element captured, in depth-first order.
    public let elements: [ElementReference]
    /// True when the tree was cut short by the depth or element budget, meaning the agent should
    /// not conclude that a missing control does not exist.
    public let wasTruncated: Bool

    public init(bundleIdentifier: String?, elements: [ElementReference], wasTruncated: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.elements = elements
        self.wasTruncated = wasTruncated
    }

    /// The elements worth offering to the planner.
    public var interactiveElements: [ElementReference] {
        elements.filter(\.isInteresting)
    }

    public func element(withID id: String) -> ElementReference? {
        elements.first { $0.id == id }
    }

    /// Finds the element that best matches a label, preferring exact matches over prefixes over
    /// substrings. Used to re-resolve a planned target against a fresh snapshot.
    public func bestMatch(forLabel label: String, role: String? = nil) -> ElementReference? {
        let needle = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let candidates = elements.filter { element in
            guard element.isEnabled else { return false }
            guard role == nil || element.role == role else { return false }
            return element.bestLabel != nil
        }
        func score(_ element: ElementReference) -> Int {
            guard let haystack = element.bestLabel?.lowercased() else { return 0 }
            if haystack == needle { return 3 }
            if haystack.hasPrefix(needle) { return 2 }
            if haystack.contains(needle) { return 1 }
            return 0
        }
        return candidates
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            // Prefer the strongest match; break ties toward actionable elements.
            .max { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : (!lhs.0.actions.isEmpty ? false : !rhs.0.actions.isEmpty)
            }?
            .0
    }
}

/// Everything AbleKit knows about the desktop at one instant.
///
/// Context is ephemeral by design (brief §6, §19): it is collected when a step needs it, handed to
/// the planner, and dropped. Nothing here is persisted.
public struct DesktopContext: Sendable {
    public let capturedAt: Date
    public let frontmostApplication: RunningApplicationInfo?
    public let focusedWindow: WindowInfo?
    public let visibleWindows: [WindowInfo]
    public let selectedText: String?
    public let clipboard: ClipboardSnapshot?
    /// Paths of items selected in Finder, when Finder is the frontmost application.
    public let finderSelection: [String]
    public let accessibility: AccessibilitySnapshot?
    public let screen: ScreenObservation?
    public let arrangement: ScreenArrangement

    public init(
        capturedAt: Date = Date(),
        frontmostApplication: RunningApplicationInfo? = nil,
        focusedWindow: WindowInfo? = nil,
        visibleWindows: [WindowInfo] = [],
        selectedText: String? = nil,
        clipboard: ClipboardSnapshot? = nil,
        finderSelection: [String] = [],
        accessibility: AccessibilitySnapshot? = nil,
        screen: ScreenObservation? = nil,
        arrangement: ScreenArrangement = ScreenArrangement(displays: [])
    ) {
        self.capturedAt = capturedAt
        self.frontmostApplication = frontmostApplication
        self.focusedWindow = focusedWindow
        self.visibleWindows = visibleWindows
        self.selectedText = selectedText
        self.clipboard = clipboard
        self.finderSelection = finderSelection
        self.accessibility = accessibility
        self.screen = screen
        self.arrangement = arrangement
    }

    /// A short fingerprint of what is on screen, used to notice that an action changed nothing.
    ///
    /// Deliberately coarse: it reflects the app, the window, and the shape of the interface, so
    /// that a spinner or a clock tick does not read as progress, and a genuinely new dialog does.
    public var stateFingerprint: String {
        var parts: [String] = []
        parts.append(frontmostApplication?.bundleIdentifier ?? "none")
        parts.append(focusedWindow?.title ?? "no-window")
        if let accessibility {
            let interactive = accessibility.interactiveElements
            parts.append("ax:\(interactive.count)")
            // The labels of the first handful of controls change when the pane changes but not
            // when a value merely ticks over.
            parts.append(interactive.prefix(12).compactMap(\.bestLabel).joined(separator: "|"))
        }
        if let focused = accessibility?.elements.first(where: \.isFocused) {
            parts.append("focus:\(focused.id)")
        }
        return parts.joined(separator: "\u{1F}")
    }
}
