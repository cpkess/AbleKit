import CoreGraphics
import Testing

@testable import AbleKitCore

/// A two-display arrangement: a Retina primary, with a non-Retina display to its left.
/// A display at negative x is the case that most often breaks naive coordinate math.
private let arrangement = ScreenArrangement(displays: [
    DisplayGeometry(
        displayID: 1,
        bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        scaleFactor: 2,
        isPrimary: true
    ),
    DisplayGeometry(
        displayID: 2,
        bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        scaleFactor: 1,
        isPrimary: false
    ),
])

@Suite("Coordinate conversion")
struct GeometryTests {

    @Test("Flipping a point twice returns the original")
    func pointFlipIsItsOwnInverse() {
        let original = CGPoint(x: 400, y: 120)
        let flipped = Geometry.flip(point: original, primaryDisplayHeight: 982)
        #expect(flipped == CGPoint(x: 400, y: 862))
        #expect(Geometry.flip(point: flipped, primaryDisplayHeight: 982) == original)
    }

    @Test("Flipping a rect accounts for its height")
    func rectFlipUsesHeight() {
        // An AppKit rect sitting on the bottom edge of the primary display.
        let appKit = CGRect(x: 10, y: 0, width: 100, height: 40)
        let canonical = Geometry.flip(rect: appKit, primaryDisplayHeight: 982)
        // Its top edge is 40pt above the bottom of the screen: 982 - 40.
        #expect(canonical == CGRect(x: 10, y: 942, width: 100, height: 40))
        #expect(Geometry.flip(rect: canonical, primaryDisplayHeight: 982) == appKit)
    }

    @Test("AppKit conversions are anchored to the primary display, not the containing one")
    func appKitConversionUsesPrimaryHeight() {
        // A point on the taller secondary display still flips about the primary's height.
        let canonical = arrangement.canonicalPoint(fromAppKit: CGPoint(x: -1000, y: 82))
        #expect(canonical == CGPoint(x: -1000, y: 900))
        #expect(arrangement.appKitPoint(fromCanonical: canonical) == CGPoint(x: -1000, y: 82))
    }

    @Test("Points are resolved to the display that contains them")
    func displayLookup() {
        #expect(arrangement.display(containing: CGPoint(x: 100, y: 100))?.displayID == 1)
        #expect(arrangement.display(containing: CGPoint(x: -100, y: 100))?.displayID == 2)
        #expect(arrangement.display(containing: CGPoint(x: 5000, y: 100)) == nil)
        #expect(arrangement.contains(CGPoint(x: 0, y: 0)))
    }

    @Test("A shared display edge belongs to exactly one display")
    func edgesAreHalfOpen() {
        // x = 0 is the primary's minX and the secondary's maxX; only one may claim it.
        #expect(arrangement.display(containing: CGPoint(x: 0, y: 500))?.displayID == 1)
        #expect(arrangement.display(containing: CGPoint(x: -1920, y: 500))?.displayID == 2)
    }

    @Test("Total bounds span every display")
    func totalBounds() {
        #expect(arrangement.totalBounds == CGRect(x: -1920, y: 0, width: 3432, height: 1080))
    }
}

@Suite("Capture geometry")
struct CaptureGeometryTests {

    /// A Retina capture of a window that is not at the screen origin: 800x600 points at 2x.
    private let capture = CaptureGeometry(
        region: CGRect(x: 200, y: 100, width: 800, height: 600),
        pixelSize: CGSize(width: 1600, height: 1200)
    )

    @Test("Scale is derived from pixels per point")
    func scale() {
        #expect(capture.scaleX == 2)
        #expect(capture.scaleY == 2)
    }

    @Test("Pixel and screen conversions round-trip")
    func pixelRoundTrip() {
        let screen = capture.canonicalPoint(fromPixel: CGPoint(x: 400, y: 200))
        // 400px / 2 = 200pt from the region's left edge, which starts at x = 200.
        #expect(screen == CGPoint(x: 400, y: 200))
        #expect(capture.pixelPoint(fromCanonical: screen) == CGPoint(x: 400, y: 200))
    }

    @Test("A Vision box is scaled into the region and flipped to a top-left origin")
    func normalizedBoxConversion() {
        // Bottom-left quarter of the image in Vision's space.
        let box = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let rect = capture.canonicalRect(fromNormalized: box)
        // Bottom-left in Vision space is the *lower* half on screen: y runs 400..700.
        #expect(rect == CGRect(x: 200, y: 400, width: 400, height: 300))
    }

    @Test("A Vision box at the top of the image maps to the top of the region")
    func normalizedTopEdge() {
        let box = CGRect(x: 0, y: 0.9, width: 1, height: 0.1)
        let rect = capture.canonicalRect(fromNormalized: box)
        #expect(rect.minY.isApproximatelyEqual(to: 100))  // the region's own top edge
        #expect(rect.height.isApproximatelyEqual(to: 60))
    }

    @Test("A degenerate capture does not divide by zero")
    func degenerateCapture() {
        let empty = CaptureGeometry(region: .zero, pixelSize: .zero)
        #expect(empty.scaleX == 1)
        #expect(empty.scaleY == 1)
    }

    @Test("Element centre is the click target")
    func center() {
        #expect(CGRect(x: 10, y: 20, width: 100, height: 40).center == CGPoint(x: 60, y: 40))
    }
}

extension CGFloat {
    fileprivate func isApproximatelyEqual(to other: CGFloat, tolerance: CGFloat = 0.0001) -> Bool {
        abs(self - other) < tolerance
    }
}
