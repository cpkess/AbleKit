import AppKit
import Foundation

/// Assembles the desktop context AbleKit reasons over.
///
/// The collector is the boundary between the machine and everything else in AbleKit, and it is
/// built around one rule: **gather the least that will do**. Context is collected fresh for each
/// step and thrown away afterwards, screen capture happens only when it is asked for, and the
/// screenshot never leaves memory. What the user gets from that is an agent whose recording
/// indicator is dark for most of a task, and a privacy claim that is structural rather than
/// promised (brief §19).
public struct ContextCollector: ContextCollecting {

    private let accessibility: AccessibilityService
    private let capture: any ScreenCapturing
    private let recognizer: any TextRecognizing
    private let permissions: any PermissionChecking

    public init(
        accessibility: AccessibilityService = AccessibilityService(),
        capture: any ScreenCapturing = ScreenCaptureService(),
        recognizer: any TextRecognizing = VisionService(),
        permissions: any PermissionChecking = SystemPermissionChecker()
    ) {
        self.accessibility = accessibility
        self.capture = capture
        self.recognizer = recognizer
        self.permissions = permissions
    }

    public func collect(options: ContextCollectionOptions) async -> DesktopContext {
        let frontmost = Self.frontmostApplication()
        let arrangement = await capture.screenArrangement()

        async let visibleWindows = capture.visibleWindows()

        var snapshot: AccessibilitySnapshot?
        var focusedWindow: WindowInfo?
        var selectedText: String?
        var finderSelection: [String] = []

        if options.includesAccessibility, permissions.status(of: .accessibility).isGranted,
            let frontmost
        {
            // Accessibility is synchronous IPC into another process, so the whole read happens off
            // the calling actor in one go rather than hopping per attribute.
            let reading = await Self.readAccessibility(
                using: accessibility,
                application: frontmost,
                options: options,
                includesUserContent: options.includesUserContent
            )
            snapshot = reading.snapshot
            focusedWindow = reading.window
            selectedText = reading.selectedText
            finderSelection = reading.selectedFiles
        }

        var screen: ScreenObservation?
        if options.includesScreenshot, permissions.status(of: .screenRecording).isGranted,
            let frontmost
        {
            screen = await captureScreen(
                processIdentifier: frontmost.processIdentifier,
                recognizingText: options.includesScreenText
            )
        }

        return DesktopContext(
            frontmostApplication: frontmost,
            focusedWindow: focusedWindow,
            visibleWindows: await visibleWindows,
            selectedText: selectedText,
            clipboard: options.includesUserContent ? Self.clipboard() : nil,
            finderSelection: finderSelection,
            accessibility: snapshot,
            screen: screen,
            arrangement: arrangement
        )
    }

    // MARK: - Pieces

    private struct AccessibilityReading: Sendable {
        var snapshot: AccessibilitySnapshot?
        var window: WindowInfo?
        var selectedText: String?
        var selectedFiles: [String] = []
    }

    private static func readAccessibility(
        using service: AccessibilityService,
        application: RunningApplicationInfo,
        options: ContextCollectionOptions,
        includesUserContent: Bool
    ) async -> AccessibilityReading {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let processIdentifier = application.processIdentifier
                var reading = AccessibilityReading()
                reading.snapshot = service.snapshot(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    maximumElements: options.maximumElements,
                    maximumDepth: options.maximumDepth
                )
                reading.window = service.focusedWindow(
                    processIdentifier: processIdentifier,
                    applicationName: application.localizedName,
                    bundleIdentifier: application.bundleIdentifier
                )
                if includesUserContent {
                    reading.selectedText = service.selectedText(processIdentifier: processIdentifier)
                    if application.bundleIdentifier == "com.apple.finder" {
                        reading.selectedFiles = service.selectedFileURLs(
                            processIdentifier: processIdentifier
                        )
                    }
                }
                continuation.resume(returning: reading)
            }
        }
    }

    private func captureScreen(
        processIdentifier: pid_t,
        recognizingText: Bool
    ) async -> ScreenObservation? {
        guard let capture = try? await capture.captureWindow(ofProcess: processIdentifier) else {
            return nil
        }
        let text = recognizingText ? await recognizer.recognizeText(in: capture) : []
        return ScreenObservation(image: capture.image, geometry: capture.geometry, textRegions: text)
    }

    private static func frontmostApplication() -> RunningApplicationInfo? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return RunningApplicationInfo(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName ?? "Unknown",
            processIdentifier: application.processIdentifier,
            isActive: application.isActive
        )
    }

    private static func clipboard() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)
        let hasImage = pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        // Only a bounded prefix is kept: the clipboard can hold a whole document, and none of it
        // is worth spending the model's context on.
        return ClipboardSnapshot(
            text: text.map { String($0.prefix(2000)) },
            hasImage: hasImage
        )
    }
}
