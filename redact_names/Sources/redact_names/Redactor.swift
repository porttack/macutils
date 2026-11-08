import Foundation
import CoreGraphics

/// Settings that control how pages are redacted (filled in from the command-line flags).
struct RedactOptions {
    var preview = false
    var pad: CGFloat = 1.5            // vertical padding, in line heights
    var margin: CGFloat = 8           // extra pixels around each box
    var fallbackTop: CGFloat? = nil   // if no "Name:" on page 1, black out this top fraction
    var dpi = 200
    var roster: RosterMatcher? = nil
    var explain = false
    var names: NameDetector? = nil    // finds name-like words anywhere (nil = off)
    var scope = Scope.page
    var headerFraction: CGFloat = 0.22   // header scope: top fraction of each page that counts as the header
    var namePagesAll = false             // look for a "Name:" label on every page, not just the first
    var nameExtent = NameExtent.width    // how far the name band runs
    var inferNameArea = true             // copy the Name area to pages where the label wasn't found (if most had it)
    var sideMargin: CGFloat = 0.05       // width extent: fraction of the page width kept clear on each side
    var nameLines = 1                    // also black out this many lines directly below the Name line
}

/// Where redaction is allowed to happen.
enum Scope: String, CaseIterable {
    /// The Name: label on page 1, plus name-like words and roster names anywhere on any page.
    case page
    /// Only the top of EACH page: the Name: label, plus name-like words and roster names inside the header.
    /// The body of the page is never touched.
    case header
}

/// Which pages are searched for a "Name:" label.
enum NamePages: String, CaseIterable { case first, all }

/// How far the Name band runs.
enum NameExtent: String, CaseIterable {
    case width  // one strip across most of the page, keeping the side margins (default: the surest)
    case stop   // from the label to the next printed label (Date, Period, ...), which stay visible
    case edge   // from the label to the page edge, ignoring printed labels
}

/// What happened on one page.
struct PageResult {
    var boxes: [CGRect] = []          // image space
    var firstPageMissingLabel = false
    var checkReason: String? = nil    // why this page needs a human look, if it does
    var searchedLabel = false         // was this page searched for a Name: label?
    var nameUnion: CGRect? = nil      // union of this page's Name bands (image space), if the label was found
    var pageSize: CGSize = .zero
    var inferredNameArea = false      // the Name area was copied from other pages
    var rosterHits = 0
    var nameHits = 0
    var explanations: [String] = []   // filled only when options.explain is set
}

enum Redactor {
    /// Decide what to black out on one page.
    static func plan(page index: Int, image: CGImage, options: RedactOptions) throws -> PageResult {
        var result = PageResult()
        let size = CGSize(width: image.width, height: image.height)
        result.pageSize = size
        let header = options.scope == .header

        // Which pages get the label search: every page in header scope (each sheet in a class PDF has a
        // name at the top); otherwise page 1, or every page with --name-pages all.
        let searchLabel = header || options.namePagesAll || index == 0
        guard searchLabel || options.roster != nil || options.names != nil else { return result }
        let lines = try OCR.readLines(in: image, customWords: options.roster?.customWords ?? [])

        // 1. The "Name:" label.
        var bands: [CGRect] = []
        if searchLabel {
            bands = NameFinder.findBands(in: lines, imageSize: size, pad: options.pad, margin: options.margin,
                                         extent: options.nameExtent, sideMargin: options.sideMargin,
                                         extraLines: options.nameLines)
            result.boxes += bands
            result.searchedLabel = true
            result.nameUnion = bands.dropFirst().reduce(bands.first) { $0?.union($1) }
            if bands.isEmpty, index == 0 {
                result.firstPageMissingLabel = true
                result.checkReason = "no Name: label"
                if let f = options.fallbackTop {
                    result.boxes.append(CGRect(x: 0, y: 0, width: size.width, height: size.height * f))
                }
            }
        }

        // In header scope, nothing below the header is touched. The header is the top fraction of the
        // page, stretched down to include the Name band and the line(s) under it.
        var zoneBottom = size.height
        if header {
            zoneBottom = max(options.headerFraction * size.height, (bands.map(\.maxY).max() ?? 0) + options.margin)
        }
        let inZone = lines.filter { $0.rect.midY <= zoneBottom }

        // 2. Roster names: black out the whole OCR line.
        if let roster = options.roster {
            for line in inZone where roster.matches(line.text) {
                result.boxes.append(Geometry.inflate(line.rect, by: options.margin, within: size))
                result.rosterHits += 1
            }
        }

        // 3. Anything that looks like a name: black out just that word.
        if let detector = options.names {
            for line in inZone {
                for hit in detector.hits(in: line.text) {
                    let range = hit.range
                    if options.explain {
                        result.explanations.append("\"\(line.text[range])\" -> \(hit.reason)")
                    }
                    let box = line.rect(of: range) ?? line.estimatedRect(of: range)
                    // Word boxes from handwriting are loose, so pad by a fraction of the line height too.
                    let slack = options.margin + 0.25 * line.rect.height
                    result.boxes.append(Geometry.inflate(box, by: slack, within: size))
                    result.nameHits += 1
                }
            }
        }

        // Header scope: a page with no Name: label is normally fine (a back side), but name-like text at
        // the top with no label is worth a look.
        if header, bands.isEmpty, index > 0, result.nameHits + result.rosterHits > 0 {
            result.checkReason = "name-like text at the top but no Name: label"
        }
        return result
    }

    /// If most pages that were searched had a Name area, the handout is the same printed form on every sheet,
    /// so the area sits in the same place. Copy the typical area (the median position) onto the pages where
    /// the label wasn't found, because OCR misread it.
    static func inferNameAreas(_ results: inout [PageResult], options: RedactOptions) {
        let eligible = results.indices.filter { results[$0].searchedLabel }
        let found = eligible.filter { results[$0].nameUnion != nil }
        guard !found.isEmpty, found.count < eligible.count else { return }

        // Not enough pages to infer from (or inference is off): don't let a page with no label pass quietly
        // when its neighbors had one. A human should look.
        guard options.inferNameArea, eligible.count >= 3, found.count * 2 > eligible.count else {
            for i in eligible where results[i].nameUnion == nil && results[i].checkReason == nil {
                results[i].checkReason = "no Name: label on this page, but other pages had one"
            }
            return
        }

        func median(_ v: [CGFloat]) -> CGFloat { v.sorted()[v.count / 2] }
        func fractions(_ i: Int) -> [CGFloat] {
            let u = results[i].nameUnion!, s = results[i].pageSize
            return [u.minX / s.width, u.minY / s.height, u.maxX / s.width, u.maxY / s.height]
        }
        let all = found.map(fractions)
        let m = (0..<4).map { k in median(all.map { $0[k] }) }

        for i in eligible where results[i].nameUnion == nil {
            let s = results[i].pageSize
            let area = CGRect(x: m[0] * s.width, y: m[1] * s.height,
                              width: (m[2] - m[0]) * s.width, height: (m[3] - m[1]) * s.height)
            results[i].boxes.append(Geometry.inflate(area, by: options.margin, within: s))
            results[i].inferredNameArea = true
            // Covered now, so these two "no label" flags no longer apply.
            results[i].checkReason = nil
        }
    }
}
