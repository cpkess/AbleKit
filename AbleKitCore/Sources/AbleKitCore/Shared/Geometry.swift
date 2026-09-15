import CoreGraphics
import Foundation

/// AbleKit uses a single canonical coordinate space for every action it executes.
///
/// **Canonical space** = global screen coordinates, **top-left origin**, **measured in points**.
/// This matches CoreGraphics event coordinates (`CGEvent`) and the Accessibility APIs
/// (`kAXPositionAttribute`), which are the two systems that actually receive our actions.
///
/// Two other spaces show up at the edges of the system and are converted here, and only here:
///
/// - **AppKit space** (`NSScreen`, `NSWindow`): bottom-left origin, points. Used by the UI layer.
/// - **Image space** (`ScreenCaptureKit` output, `Vision` observations): pixels, and in Vision's
///   case normalized `0...1` with a bottom-left origin.
///
/// Keeping the math in this file is a deliberate architectural constraint: coordinate bugs are
/// the single most common source of silent misclicks in desktop automation, and they are only
/// debuggable if the conversion happens in one testable place.
public enum Geometry {

    // MARK: - AppKit <-> canonical

    /// Flips a point between AppKit's bottom-left origin and the canonical top-left origin.
    ///
    /// The flip is defined by the *primary* display's height, because both global spaces are
    /// anchored to the primary display, not to whichever display the point happens to land on.
    /// The conversion is its own inverse.
    public static func flip(point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// Flips a rect between AppKit's bottom-left origin and the canonical top-left origin.
    ///
    /// A rect needs its *height* accounted for as well as its origin: the bottom-left corner in
    /// one space is the top-left corner in the other. The conversion is its own inverse.
    public static func flip(rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Describes one physical display in canonical space.
public struct DisplayGeometry: Sendable, Equatable, Codable {
    /// `CGDirectDisplayID` of the display.
    public let displayID: UInt32
    /// The display's bounds in canonical space (global, top-left origin, points).
    public let bounds: CGRect
    /// Backing scale factor (2.0 on Retina displays). Points × scale = pixels.
    public let scaleFactor: CGFloat
    /// Whether this is the primary display, i.e. the one whose top-left corner is the canonical origin.
    public let isPrimary: Bool

    public init(displayID: UInt32, bounds: CGRect, scaleFactor: CGFloat, isPrimary: Bool) {
        self.displayID = displayID
        self.bounds = bounds
        self.scaleFactor = scaleFactor
        self.isPrimary = isPrimary
    }

    /// The display's full resolution in pixels.
    public var pixelSize: CGSize {
        CGSize(width: bounds.width * scaleFactor, height: bounds.height * scaleFactor)
    }
}

/// The arrangement of every display attached to the machine, in canonical space.
///
/// Actions are validated against this before execution: a click that lands outside every display
/// is rejected rather than silently dispatched into nowhere (see `ActionValidator`).
public struct ScreenArrangement: Sendable, Equatable, Codable {
    public let displays: [DisplayGeometry]

    public init(displays: [DisplayGeometry]) {
        self.displays = displays
    }

    public var primary: DisplayGeometry? {
        displays.first(where: \.isPrimary) ?? displays.first
    }

    /// Height used to flip between AppKit and canonical space.
    public var primaryDisplayHeight: CGFloat {
        primary?.bounds.height ?? 0
    }

    /// The smallest rect containing every display.
    public var totalBounds: CGRect {
        guard let first = displays.first else { return .zero }
        return displays.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// The display containing `point`, if any.
    ///
    /// Bounds are treated as half-open (`minX..<maxX`) so that adjacent displays never both claim
    /// a point on their shared edge.
    public func display(containing point: CGPoint) -> DisplayGeometry? {
        displays.first { display in
            point.x >= display.bounds.minX && point.x < display.bounds.maxX
                && point.y >= display.bounds.minY && point.y < display.bounds.maxY
        }
    }

    /// Whether `point` falls on some display.
    public func contains(_ point: CGPoint) -> Bool {
        display(containing: point) != nil
    }

    // MARK: - AppKit bridging

    /// Converts an AppKit (bottom-left origin) point into canonical space.
    public func canonicalPoint(fromAppKit point: CGPoint) -> CGPoint {
        Geometry.flip(point: point, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// Converts a canonical point into AppKit's (bottom-left origin) space.
    public func appKitPoint(fromCanonical point: CGPoint) -> CGPoint {
        Geometry.flip(point: point, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// Converts an AppKit (bottom-left origin) rect into canonical space.
    public func canonicalRect(fromAppKit rect: CGRect) -> CGRect {
        Geometry.flip(rect: rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// Converts a canonical rect into AppKit's (bottom-left origin) space.
    public func appKitRect(fromCanonical rect: CGRect) -> CGRect {
        Geometry.flip(rect: rect, primaryDisplayHeight: primaryDisplayHeight)
    }
}

/// Maps between a captured image's pixels and canonical screen points.
///
/// A capture is always of some rectangle of the screen, rendered at some pixel size. Those two
/// facts are all that is needed to place anything found in the image — an OCR box, a detected
/// control — back onto the real screen.
public struct CaptureGeometry: Sendable, Equatable, Codable {
    /// The region of the screen that was captured, in canonical space.
    public let region: CGRect
    /// The pixel dimensions of the resulting image.
    public let pixelSize: CGSize

    public init(region: CGRect, pixelSize: CGSize) {
        self.region = region
        self.pixelSize = pixelSize
    }

    /// Pixels per point along x. `1` for a non-scaled capture, `2` for a Retina-resolution capture.
    public var scaleX: CGFloat {
        pixelSize.width > 0 && region.width > 0 ? pixelSize.width / region.width : 1
    }

    /// Pixels per point along y.
    public var scaleY: CGFloat {
        pixelSize.height > 0 && region.height > 0 ? pixelSize.height / region.height : 1
    }

    /// Converts a pixel coordinate in the captured image (top-left origin) to canonical screen points.
    public func canonicalPoint(fromPixel pixel: CGPoint) -> CGPoint {
        CGPoint(
            x: region.origin.x + pixel.x / scaleX,
            y: region.origin.y + pixel.y / scaleY
        )
    }

    /// Converts a canonical screen point to a pixel coordinate in the captured image.
    public func pixelPoint(fromCanonical point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - region.origin.x) * scaleX,
            y: (point.y - region.origin.y) * scaleY
        )
    }

    /// Converts a pixel rect in the captured image (top-left origin) to canonical screen points.
    public func canonicalRect(fromPixel rect: CGRect) -> CGRect {
        CGRect(
            x: region.origin.x + rect.origin.x / scaleX,
            y: region.origin.y + rect.origin.y / scaleY,
            width: rect.width / scaleX,
            height: rect.height / scaleY
        )
    }

    /// Converts a Vision observation's normalized bounding box to canonical screen points.
    ///
    /// Vision reports boxes in a `0...1` space with a **bottom-left** origin, so this both scales
    /// into the capture region and flips the y axis.
    public func canonicalRect(fromNormalized box: CGRect) -> CGRect {
        let width = box.width * region.width
        let height = box.height * region.height
        return CGRect(
            x: region.origin.x + box.origin.x * region.width,
            // Flip within the region: Vision's y counts up from the region's bottom edge.
            y: region.origin.y + (1 - box.origin.y - box.height) * region.height,
            width: width,
            height: height
        )
    }
}

extension CGRect {
    /// The centre of the rect — the point AbleKit aims at when clicking an element.
    public var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
