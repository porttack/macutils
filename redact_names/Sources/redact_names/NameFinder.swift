import Foundation
import CoreGraphics

/// Finds the "Name:" label near the top of a page and works out the band to black out.
enum NameFinder {

    /// A label that ends the name field when it appears to the right of "Name:".
    static let stopWords = ["date", "period", "class", "block", "hour",
                            "teacher", "score", "grade", "due"]

    // "Name:" (colon or semicolon, which OCR sometimes produces) or a line that is just "Name".
    // Also "Name" at the start of a line followed by up to three words and no colon: a student often writes
    // straight after a printed "Name" that has no colon, and OCR then returns one line like "Name Maria G".
    private static let labelRegex = try! NSRegularExpression(
        pattern: #"\bname\b\s*[:;]|^\s*name\s*$|^\s*name\b(\s+\S+){1,3}\s*$"#, options: .caseInsensitive)

    private static let stopRegex = try! NSRegularExpression(
        pattern: "\\b(" + stopWords.joined(separator: "|") + ")\\b", options: .caseInsensitive)

    /// Only look for labels in the top part of the page.
    static let searchFraction: CGFloat = 0.4

    /// Returns the boxes to black out for each "Name:" label found (usually one label). Empty = no label.
    /// All rects are in image space.
    ///
    /// - extent .width (default): one strip across most of the page (keeping `sideMargin` on each side),
    ///   from above the Name line to below the row after it. No guessing where the writing ends.
    /// - extent .stop / .edge: a band from the label to the next printed label / the page edge, plus
    ///   `extraLines` rows below.
    /// - extraLines: rows below the Name line that are also covered, because a first and last name often
    ///   wrap onto a second line. These rows are placed by geometry, not by what OCR found.
    static func findBands(in lines: [TextLine], imageSize: CGSize, pad: CGFloat, margin: CGFloat,
                          extent: NameExtent = .width, sideMargin: CGFloat = 0.05,
                          extraLines: Int = 1) -> [CGRect] {
        var bands: [CGRect] = []

        for (i, line) in lines.enumerated() where line.rect.midY < imageSize.height * searchFraction {
            let text = line.text
            guard let labelRange = findLabel(in: text) else { continue }

            // For "Name Maria G" (no colon) the match covers the whole line; the label is just the first word.
            let labelEnd = text.range(of: "name", options: .caseInsensitive, range: labelRange)?.upperBound ?? labelRange.upperBound
            let labelOnly = labelRange.lowerBound..<min(labelEnd, labelRange.upperBound)
            let labelRect = line.rect(of: labelOnly) ?? estimate(labelOnly, in: line)
            let startX = labelRect.maxX
            var endX = imageSize.width                 // default: run to the page edge
            var handwriting: [CGRect] = []             // where the written name actually is

            // 1. Text after the label inside the SAME observation (Vision merged them).
            let rest = labelOnly.upperBound..<text.endIndex
            if extent == .stop, let stop = firstStop(in: text, range: rest) {
                endX = min(endX, line.rect(of: stop)?.minX ?? estimate(stop, in: line).minX)
                let name = labelOnly.upperBound..<stop.lowerBound
                if hasInk(text[name]), let r = line.rect(of: name) { handwriting.append(r) }
            } else if hasInk(text[rest]), let r = line.rect(of: rest) {
                handwriting.append(r)
            }

            // 2. Other observations on the same row, to the right of the label.
            for (j, other) in lines.enumerated() where j != i {
                let sameRow = abs(other.rect.midY - labelRect.midY) < labelRect.height * 0.75
                guard sameRow, other.rect.midX > startX else { continue }
                let all = other.text.startIndex..<other.text.endIndex
                if extent == .stop, let stop = firstStop(in: other.text, range: all) {
                    endX = min(endX, other.rect(of: stop)?.minX ?? estimate(stop, in: other).minX)
                    let before = other.text.startIndex..<stop.lowerBound
                    if hasInk(other.text[before]), let r = other.rect(of: before) { handwriting.append(r) }
                } else {
                    handwriting.append(other.rect)
                }
            }
            handwriting = handwriting.filter { $0.minX < endX }

            // Vertical extent of the Name row: label plus any handwriting, padded (handwriting drifts up).
            let rows = [labelRect] + handwriting
            let lineHeight = labelRect.height
            let top = rows.map(\.minY).min()! - pad * lineHeight
            let bottom = rows.map(\.maxY).max()! + 0.5 * lineHeight

            if extent == .width {
                bands.append(widthStrip(lines: lines, skipping: i, rows: rows, top: top,
                                        bottom: bottom + 1.8 * lineHeight * CGFloat(extraLines),
                                        imageSize: imageSize, sideMargin: sideMargin, margin: margin))
                continue
            }

            let band = CGRect(x: startX, y: top, width: max(endX - startX, 0), height: bottom - top)
            var padded = Geometry.inflate(band, by: margin, within: imageSize)
            // The margin must not eat into the next label (e.g. the "D" of "Date:").
            if endX < imageSize.width { padded.size.width = endX - padded.minX }
            bands.append(padded)

            // 3. The row(s) directly below the Name line, by GEOMETRY, not by what OCR found. A name that wraps
            //    puts its last name on the next line, and OCR often fails to read handwriting, so we cannot
            //    rely on it seeing that line. Each row starts at the label's left edge and runs to the next
            //    printed label (e.g. "Period:", which OCR reads reliably) or the page edge.
            var rowBottom = bottom
            for _ in 0..<extraLines {
                let rowTop = rowBottom - 0.2 * lineHeight
                var rowEnd = rowBottom + 1.8 * lineHeight
                var right = imageSize.width
                if extent == .stop {
                    for other in lines where other.rect.midY > rowTop && other.rect.midY < rowEnd && other.rect.midX > labelRect.minX {
                        let all = other.text.startIndex..<other.text.endIndex
                        if let stop = firstStop(in: other.text, range: all) {
                            right = min(right, other.rect(of: stop)?.minX ?? estimate(stop, in: other).minX)
                        }
                    }
                }
                var t = rowTop
                for other in lines where other.rect.minX < right - 1 {
                    let overlap = min(other.rect.maxY, rowEnd) - max(other.rect.minY, t)
                    if overlap > 0.3 * other.rect.height, other.rect.minY > labelRect.maxY - 0.2 * lineHeight {
                        t = min(t, other.rect.minY); rowEnd = max(rowEnd, other.rect.maxY)
                    }
                }
                var r = Geometry.inflate(CGRect(x: labelRect.minX, y: t, width: max(right - labelRect.minX, 0), height: rowEnd - t),
                                         by: margin, within: imageSize)
                if right < imageSize.width { r.size.width = right - r.minX }
                bands.append(r)
                rowBottom = rowEnd
            }
        }
        return bands
    }

    /// One strip across most of the page. Its top and bottom edges are snapped around printed lines so a line
    /// is either covered completely or left alone: no jagged, half-covered text.
    private static func widthStrip(lines: [TextLine], skipping: Int, rows: [CGRect], top: CGFloat, bottom: CGFloat,
                                   imageSize: CGSize, sideMargin: CGFloat, margin: CGFloat) -> CGRect {
        var top = top, bottom = bottom
        let nameTop = rows.map(\.minY).min()!, nameBottom = rows.map(\.maxY).max()!
        for _ in 0..<2 {                                     // a second pass catches lines revealed by extending
            for (j, o) in lines.enumerated() where j != skipping {
                let overlap = min(o.rect.maxY, bottom) - max(o.rect.minY, top)
                guard overlap > 0, !(o.rect.minY >= top && o.rect.maxY <= bottom) else { continue }   // cut by an edge
                let cutsTop = o.rect.midY < (top + bottom) / 2
                // Lines above the name need to be mostly inside to be taken in; below, a third is enough
                // (a name's last line may start there). Otherwise the strip stops short of them.
                if overlap >= (cutsTop ? 0.75 : 0.3) * o.rect.height {
                    top = min(top, o.rect.minY); bottom = max(bottom, o.rect.maxY)
                } else if cutsTop {
                    top = min(max(top, o.rect.maxY + 2), nameTop - 2)
                } else {
                    bottom = max(min(bottom, o.rect.minY - 2), nameBottom + 2)
                }
            }
        }
        let x0 = sideMargin * imageSize.width
        let strip = CGRect(x: x0, y: top - margin, width: imageSize.width - 2 * x0, height: bottom - top + 2 * margin)
        return strip.intersection(CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - Helpers

    /// The "Name" label in a line of OCR text, or nil. First the exact patterns; then a forgiving match on the
    /// line's first word, because OCR often misreads a bold printed "Name" with handwriting jammed against it
    /// ("Nome", "Narne", "Name:" glued to a scribble).
    private static func findLabel(in text: String) -> Range<String.Index>? {
        if let m = labelRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text) { return r }
        guard let first = text.split(whereSeparator: { !$0.isLetter }).first, first.count >= 3, first.count <= 6,
              text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(first.lowercased()) else { return nil }
        // "rn" reads like "m", the classic OCR confusion: "Narne" is "Name".
        let word = first.lowercased().replacingOccurrences(of: "rn", with: "m")
        guard RosterMatcher.levenshtein(word, "name") <= 1 else { return nil }
        let start = text.firstIndex(of: first.first!) ?? text.startIndex
        return start..<(text.range(of: first, range: start..<text.endIndex)?.upperBound ?? text.endIndex)
    }

    private static func firstStop(in text: String, range: Range<String.Index>) -> Range<String.Index>? {
        guard let m = stopRegex.firstMatch(in: text, range: NSRange(range, in: text)) else { return nil }
        return Range(m.range, in: text)
    }

    /// True if the text contains something besides whitespace, underscores and punctuation.
    private static func hasInk<S: StringProtocol>(_ s: S) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    private static func estimate(_ range: Range<String.Index>, in line: TextLine) -> CGRect {
        line.estimatedRect(of: range)
    }
}
