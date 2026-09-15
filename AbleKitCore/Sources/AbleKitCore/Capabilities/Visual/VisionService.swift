import CoreGraphics
import Foundation
import Vision

/// Reads text out of an image.
///
/// Vision does this deterministically, in milliseconds, and better than a language model would
/// (brief §9). The model's job is to decide what the text *means*; finding it is not a reasoning
/// problem and should not be billed as one.
public protocol TextRecognizing: Sendable {
    /// Recognises text in a capture, returning it in canonical screen coordinates.
    func recognizeText(in capture: ScreenCapture) async -> [RecognizedText]
}

public struct VisionService: TextRecognizing {

    /// Text recognised below this confidence is discarded.
    ///
    /// Low-confidence OCR on a desktop is usually an icon or a texture being read as letters, and
    /// a planner that trusts it will try to click on something that is not writing.
    public static let minimumConfidence: Float = 0.3

    public init() {}

    public func recognizeText(in capture: ScreenCapture) async -> [RecognizedText] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Interfaces are full of short labels with no surrounding sentence, so language correction
        // does more harm than good: it "fixes" product names and menu items into ordinary words.
        request.usesLanguageCorrection = false

        guard let observations = try? await request.perform(on: capture.image) else { return [] }

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            guard candidate.confidence >= Self.minimumConfidence else { return nil }
            let text = candidate.string.trimmed
            guard !text.isEmpty else { return nil }

            return RecognizedText(
                string: text,
                confidence: candidate.confidence,
                // Vision reports a normalised box with a lower-left origin; `CaptureGeometry`
                // scales it into the captured region and flips it into canonical space.
                frame: capture.geometry.canonicalRect(fromNormalized: observation.boundingBox.cgRect)
            )
        }
    }
}
