import CoreGraphics
import Foundation

/// Sends synthetic pointer input.
///
/// Every position here is in AbleKit's canonical space, which is also what `CGEvent` expects —
/// global, top-left origin, points — so no conversion happens in this file. That is the payoff of
/// keeping the coordinate math in `Geometry`: the code that actually moves the pointer contains no
/// arithmetic to get wrong.
public struct MouseController: Sendable {

    /// Where synthetic events are delivered.
    ///
    /// `cghidEventTap` places events at the very bottom of the stack, as though they came from the
    /// hardware, which is what makes them work with applications that inspect the event source.
    private static let tap = CGEventTapLocation.cghidEventTap

    public init() {}

    public func move(to point: CGPoint) throws(CapabilityError) {
        try post(type: .mouseMoved, at: point, button: .left, clickCount: 0)
    }

    public func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1)
        throws(CapabilityError)
    {
        // Moving first matters: many interfaces only reveal the control under the pointer on hover,
        // and a click that arrives without a preceding move can land on a stale hit-test.
        try move(to: point)

        for index in 1...max(count, 1) {
            try post(type: button.downEventType, at: point, button: button, clickCount: index)
            try post(type: button.upEventType, at: point, button: button, clickCount: index)
        }
    }

    public func drag(from start: CGPoint, to end: CGPoint) throws(CapabilityError) {
        try move(to: start)
        try post(type: .leftMouseDown, at: start, button: .left, clickCount: 1)
        // Intermediate moves are required: a single jump from press to release reads as a click
        // with a displaced release in most applications, not as a drag.
        for step in 1...Self.dragSteps {
            let progress = CGFloat(step) / CGFloat(Self.dragSteps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            try post(type: .leftMouseDragged, at: point, button: .left, clickCount: 1)
        }
        try post(type: .leftMouseUp, at: end, button: .left, clickCount: 1)
    }

    public func scroll(at point: CGPoint, deltaX: Int, deltaY: Int) throws(CapabilityError) {
        try move(to: point)
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: Int32(deltaX),
                wheel3: 0
            )
        else {
            throw .executionFailed("Could not create the scroll event.")
        }
        event.post(tap: Self.tap)
    }

    private static let dragSteps = 12

    private func post(
        type: CGEventType,
        at point: CGPoint,
        button: MouseButton,
        clickCount: Int
    ) throws(CapabilityError) {
        guard
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button.cgButton
            )
        else {
            // The usual cause is Accessibility permission having been revoked mid-task.
            throw .permissionRequired(.accessibility)
        }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: Self.tap)
    }
}

extension MouseButton {
    var cgButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .center: .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .center: .otherMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .center: .otherMouseUp
        }
    }
}
