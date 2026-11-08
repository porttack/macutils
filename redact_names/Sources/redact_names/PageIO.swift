import Foundation
import AppKit
import CoreText
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Loading scans into bitmaps, drawing redaction boxes, and writing flattened output.
///
/// Everything is converted to plain pixels (CGImage) first. Because the output is built
/// from those pixels, no text layer from the original PDF can survive.
/// How a redaction box looks. All of them remove the pixels completely; they differ only in appearance.
enum FillStyle: String, CaseIterable {
    case black   // solid black
    case gray    // solid light gray
    case white   // solid white (the area simply goes blank)
    case label   // solid light gray with the word REDACTED, when the box is big enough
}

enum PageIO {

    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "tif", "tiff"]

    enum Failure: Error, CustomStringConvertible {
        case unreadable(URL)
        case cannotWrite(URL)
        var description: String {
            switch self {
            case .unreadable(let u): return "could not read \(u.lastPathComponent)"
            case .cannotWrite(let u): return "could not write \(u.lastPathComponent)"
            }
        }
    }

    // MARK: Loading

    /// One CGImage per page. PDFs are rendered at `dpi`; image files are used as-is.
    static func loadPages(from url: URL, dpi: Int) throws -> [CGImage] {
        url.pathExtension.lowercased() == "pdf"
            ? try renderPDF(url, dpi: dpi)
            : try loadImages(url)
    }

    private static func renderPDF(_ url: URL, dpi: Int) throws -> [CGImage] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw Failure.unreadable(url) }
        let scale = CGFloat(dpi) / 72.0
        return try (0..<doc.pageCount).map { i in
            guard let page = doc.page(at: i) else { throw Failure.unreadable(url) }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 { box.size = CGSize(width: box.height, height: box.width) }
            let pixels = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
            // thumbnail(of:for:) renders the page upright, applying any /Rotate setting.
            let ns = page.thumbnail(of: pixels, for: .mediaBox)
            guard let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw Failure.unreadable(url)
            }
            return cg
        }
    }

    private static func loadImages(_ url: URL) throws -> [CGImage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure.unreadable(url)
        }
        return try (0..<CGImageSourceGetCount(src)).map { i in
            // Going through the thumbnail API applies EXIF rotation, so "up" really is up.
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else {
                throw Failure.unreadable(url)
            }
            return img
        }
    }

    // MARK: Drawing

    /// Returns a copy of `image` with each box (image space) covered in `style`,
    /// or outlined in red when `preview` is true.
    static func draw(boxes: [CGRect], on image: CGImage, preview: Bool, style: FillStyle = .black) -> CGImage {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        for box in boxes {
            let r = Geometry.imageToContext(box, imageHeight: CGFloat(h))   // flip y for CG
            if preview {
                ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                ctx.setLineWidth(max(3, CGFloat(w) / 400))
                ctx.stroke(r)
                continue
            }
            switch style {
            case .black: ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            case .gray, .label: ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            case .white: ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            }
            // Slightly rounded corners: a radius that scales with the page, never more than a quarter of the box.
            let radius = min(CGFloat(w) / 170, min(r.width, r.height) / 4)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            if style == .label { drawLabel("REDACTED", in: r, imageWidth: w, ctx: ctx) }
        }
        return ctx.makeImage()!
    }

    /// Centered caption on a redaction box. Skipped when the box is too small to hold it.
    private static func drawLabel(_ text: String, in r: CGRect, imageWidth: Int, ctx: CGContext) {
        let size = min(r.height * 0.4, CGFloat(imageWidth) / 1700 * 30)
        guard size >= 9 else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.4, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width + 16 <= r.width else { return }
        ctx.textPosition = CGPoint(x: r.midX - width / 2, y: r.midY - size * 0.35)
        CTLineDraw(line, ctx)
    }

    // MARK: Writing

    /// Write pages in the same format as the input file (PDF in -> image-only PDF out).
    static func write(_ pages: [CGImage], to url: URL, dpi: Int) throws {
        if url.pathExtension.lowercased() == "pdf" {
            try writePDF(pages, to: url, dpi: dpi)
        } else {
            try writeImages(pages, to: url)
        }
    }

    private static func writePDF(_ pages: [CGImage], to url: URL, dpi: Int) throws {
        let pt = 72.0 / CGFloat(dpi)
        var first = CGRect(x: 0, y: 0, width: CGFloat(pages[0].width) * pt, height: CGFloat(pages[0].height) * pt)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, nil) else { throw Failure.cannotWrite(url) }
        for img in pages {
            var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) * pt, height: CGFloat(img.height) * pt)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.draw(img, in: box)            // only a picture goes in; there is no text to leak
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func writeImages(_ pages: [CGImage], to url: URL) throws {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        default: type = .tiff
        }
        let count = type == .tiff ? pages.count : 1     // only TIFF holds multiple pages
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil) else {
            throw Failure.cannotWrite(url)
        }
        let opts = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        for img in pages.prefix(count) { CGImageDestinationAddImage(dest, img, opts) }
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(url) }
    }
}
