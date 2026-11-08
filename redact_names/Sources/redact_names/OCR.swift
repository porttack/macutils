import Vision
import CoreGraphics

/// One line of recognized text, with its position in image space.
struct TextLine {
    let text: String
    let rect: CGRect                  // whole line, image space (pixels, top-left origin)
    let recognized: VNRecognizedText  // kept so we can ask for sub-ranges
    let imageSize: CGSize

    /// Exact position of part of the line (e.g. the words after "Name:").
    /// Vision can measure a character range, so we don't have to guess.
    func rect(of range: Range<String.Index>) -> CGRect? {
        guard let obs = try? recognized.boundingBox(for: range) else { return nil }
        return Geometry.visionToImage(obs.boundingBox, imageSize: imageSize)
    }

    /// Fallback if Vision can't measure a sub-range: assume characters are evenly spaced.
    func estimatedRect(of range: Range<String.Index>) -> CGRect {
        let n = max(text.count, 1)
        let a = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / CGFloat(n)
        let b = CGFloat(text.distance(from: text.startIndex, to: range.upperBound)) / CGFloat(n)
        return CGRect(x: rect.minX + a * rect.width, y: rect.minY,
                      width: (b - a) * rect.width, height: rect.height)
    }
}

enum OCR {
    /// Run Vision text recognition (all local, on-device).
    static func readLines(in image: CGImage, customWords: [String] = []) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true     // customWords only apply when this is on
        request.customWords = customWords

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            return TextLine(text: best.string,
                            rect: Geometry.visionToImage(obs.boundingBox, imageSize: size),
                            recognized: best,
                            imageSize: size)
        }
    }
}
