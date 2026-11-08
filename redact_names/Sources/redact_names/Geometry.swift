import CoreGraphics

/// Coordinate conversions. This is the part that is easiest to get wrong, so it lives alone.
///
/// Three coordinate systems are in play:
///
///  1. Vision:        normalized (0...1), origin at the BOTTOM-left, y grows upward.
///  2. Image space:   pixels, origin at the TOP-left, y grows downward. This is how people
///                    think about a page, and it is what the rest of this program uses.
///  3. CGContext:     pixels, origin at the BOTTOM-left (used only at draw time).
///
/// We convert at the edges: Vision -> image space right after OCR, and
/// image space -> CGContext right before drawing.
enum Geometry {

    /// Vision normalized rect (bottom-left origin) -> pixel rect (top-left origin).
    static func visionToImage(_ r: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: r.minX * imageSize.width,
               y: (1 - r.maxY) * imageSize.height,   // flip: Vision's top edge is maxY
               width: r.width * imageSize.width,
               height: r.height * imageSize.height)
    }

    /// Pixel rect (top-left origin) -> CGContext rect (bottom-left origin).
    static func imageToContext(_ r: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: imageHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Grow a rect by `margin` pixels on every side, then keep it on the page.
    static func inflate(_ r: CGRect, by margin: CGFloat, within size: CGSize) -> CGRect {
        r.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: size))
    }
}
