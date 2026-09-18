import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What a capture produced: the image, and how to map it back onto the screen.
public struct ScreenCapture: Sendable {
    public let image: CGImage
    public let geometry: CaptureGeometry

    public init(image: CGImage, geometry: CaptureGeometry) {
        self.image = image
        self.geometry = geometry
    }
}

/// Captures the screen.
///
/// Captures are taken *strategically*, not continuously (brief §8). A high-frame-rate stream fed
/// into a model would be expensive, slow, and no more informative than one good frame taken at the
/// moment a decision is needed — and it would leave the system's recording indicator lit for the
/// whole session, which is its own kind of answer to whether that is reasonable.
///
/// Nothing captured here is written to disk. The image lives in memory for the step that needs it.
public protocol ScreenCapturing: Sendable {
    /// Captures the frontmost window of an application, falling back to its display.
    func captureWindow(ofProcess processIdentifier: pid_t) async throws -> ScreenCapture
    /// Captures a whole display.
    func captureDisplay(_ displayID: CGDirectDisplayID?) async throws -> ScreenCapture
    /// The current display arrangement, in canonical space.
    func screenArrangement() async -> ScreenArrangement
    /// Windows currently on screen.
    func visibleWindows() async -> [WindowInfo]
}

/// The real implementation, backed by ScreenCaptureKit.
public struct ScreenCaptureService: ScreenCapturing {

    private let permissions: any PermissionChecking

    public init(permissions: any PermissionChecking = SystemPermissionChecker()) {
        self.permissions = permissions
    }

    /// AbleKit's own windows, which must never appear in what AbleKit reads.
    ///
    /// The task window displays the step being worked on — "the display shows 12" — and a capture
    /// of the whole screen includes it. Read back as screen text, AbleKit's own narration becomes
    /// evidence about the app it is operating, and the agent starts reasoning about itself.
    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let identifier = Bundle.main.bundleIdentifier ?? "com.ablekit.AbleKit"
        return content.applications.filter { $0.bundleIdentifier == identifier }
    }

    public func captureWindow(ofProcess processIdentifier: pid_t) async throws -> ScreenCapture {
        try requirePermission()
        let content = try await shareableContent()

        // The frontmost on-screen window belonging to this process. `windows` comes back in
        // front-to-back order, so the first match is the one the user is looking at.
        guard
            let window = content.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
                    && $0.frame.width > 1 && $0.frame.height > 1
            })
        else {
            return try await captureDisplay(nil)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter: filter, region: window.frame)
    }

    public func captureDisplay(_ displayID: CGDirectDisplayID?) async throws -> ScreenCapture {
        try requirePermission()
        let content = try await shareableContent()

        guard
            let display = displayID.flatMap({ identifier in
                content.displays.first { $0.displayID == identifier }
            }) ?? content.displays.first
        else {
            throw CapabilityError.executionFailed("No display was found to capture.")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications(in: content),
            exceptingWindows: []
        )
        return try await capture(filter: filter, region: display.frame)
    }

    public func screenArrangement() async -> ScreenArrangement {
        guard let content = try? await shareableContent() else {
            return ScreenArrangement(displays: [])
        }
        let mainDisplayID = CGMainDisplayID()
        return ScreenArrangement(
            displays: content.displays.map { display in
                DisplayGeometry(
                    displayID: display.displayID,
                    bounds: display.frame,
                    // `width`/`height` are pixels while `frame` is points, so their ratio is the
                    // backing scale — which is how a Retina display is told from a scaled one.
                    scaleFactor: display.frame.width > 0
                        ? CGFloat(display.width) / display.frame.width : 1,
                    isPrimary: display.displayID == mainDisplayID
                )
            }
        )
    }

    public func visibleWindows() async -> [WindowInfo] {
        guard let content = try? await shareableContent() else { return [] }
        let ownIdentifier = Bundle.main.bundleIdentifier ?? "com.ablekit.AbleKit"
        return content.windows
            .filter { $0.isOnScreen && $0.frame.width > 1 && $0.frame.height > 1 }
            // AbleKit's own panels are not part of the desktop it is reasoning about.
            .filter { $0.owningApplication?.bundleIdentifier != ownIdentifier }
            .map { window in
                WindowInfo(
                    windowID: window.windowID,
                    title: window.title,
                    owningApplication: window.owningApplication?.applicationName,
                    owningBundleIdentifier: window.owningApplication?.bundleIdentifier,
                    frame: window.frame,
                    isOnScreen: window.isOnScreen,
                    isFocused: false
                )
            }
    }

    // MARK: - Internals

    private func requirePermission() throws(CapabilityError) {
        guard permissions.status(of: .screenRecording).isGranted else {
            throw .permissionRequired(.screenRecording)
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // ScreenCaptureKit reports a missing grant as a generic stream error, so it is
            // translated here into something onboarding can act on.
            guard permissions.status(of: .screenRecording).isGranted else {
                throw CapabilityError.permissionRequired(.screenRecording)
            }
            throw CapabilityError.executionFailed(
                "Could not read the screen: \(error.localizedDescription)"
            )
        }
    }

    /// Captures at the display's native resolution and records how the two spaces line up.
    private func capture(filter: SCContentFilter, region: CGRect) async throws -> ScreenCapture {
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        configuration.width = Int(region.width * CGFloat(scale))
        configuration.height = Int(region.height * CGFloat(scale))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        // Capturing the cursor would put AbleKit's own pointer into the image it is about to
        // reason over, which reads as a UI element that is not there.

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return ScreenCapture(
                image: image,
                geometry: CaptureGeometry(
                    region: region,
                    pixelSize: CGSize(width: image.width, height: image.height)
                )
            )
        } catch {
            throw CapabilityError.executionFailed(
                "Could not capture the screen: \(error.localizedDescription)"
            )
        }
    }
}
