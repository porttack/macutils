import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Optional second opinion: asks a vision model running on THIS machine (Ollama, localhost)
/// whether a name is still visible. Nothing leaves the computer.
struct OllamaVerifier {
    enum Verdict {
        case nameVisible(String)    // model's answer, for the console log
        case clear(String)
        case unclear(String)        // model didn't start with YES/NO; a human should look
        case unavailable(String)    // Ollama not running, model missing, etc.
    }

    let model: String
    let endpoint = URL(string: "http://localhost:11434/api/generate")!

    static let prompt = """
    This is a scanned student worksheet. Black boxes are redactions; ignore them. \
    Is any person's name (a student's or teacher's first or last name, handwritten or printed) \
    still visible anywhere on the page? Answer YES or NO on the first line. \
    If YES, say where on the page and what you can read.
    """

    func check(_ image: CGImage) async -> Verdict {
        guard let jpeg = Self.jpeg(image, maxSide: 1600) else { return .unavailable("could not encode image") }
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "prompt": Self.prompt, "stream": false,
                                   "think": false, "images": [jpeg.base64EncodedString()]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? ""
                return .unavailable("Ollama returned \(http.statusCode): \(msg.prefix(120))")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let answer = (json?["response"] as? String ?? "")
                .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let first = answer.lowercased().prefix(8)
            if first.hasPrefix("yes") { return .nameVisible(answer) }
            if first.hasPrefix("no") { return .clear(answer) }
            return .unclear(answer)
        } catch {
            return .unavailable("Ollama not reachable at localhost:11434 (\(error.localizedDescription))")
        }
    }

    /// Shrink and JPEG-encode so the request stays small and the model runs faster.
    private static func jpeg(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
