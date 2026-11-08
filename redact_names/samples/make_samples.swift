// Generates fake student worksheets (invented names only) for testing redact_names.
// Run:  swift samples/make_samples.swift      (writes into samples/)
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let W = 1700.0, H = 2200.0     // US Letter at 200 dpi
let outDir = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent()

func text(_ s: String, at p: CGPoint, font: String, size: CGFloat, in ctx: CGContext) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = CGPoint(x: p.x, y: H - p.y)      // p.y measured from the top
    CTLineDraw(line, ctx)
}

func underline(x: CGFloat, to x2: CGFloat, y: CGFloat, in ctx: CGContext) {
    ctx.move(to: CGPoint(x: x, y: H - y)); ctx.addLine(to: CGPoint(x: x2, y: H - y)); ctx.strokePath()
}

let body = ["1.  Solve for x:  3x + 7 = 22", "2.  Simplify:  (2x + 4) - (x - 1)",
            "3.  Graph the line y = 2x - 3", "4.  Explain in one sentence why a negative times a negative is positive."]

func page(_ ctx: CGContext, name: String?, labels: Bool = true, labelText: Bool = true, extra: [String] = []) {
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(2)
    text("Algebra 1 - Quiz 3", at: CGPoint(x: 120, y: 130), font: "Helvetica-Bold", size: 56, in: ctx)
    if labels {
        if labelText { text("Name:", at: CGPoint(x: 120, y: 260), font: "Helvetica", size: 44, in: ctx) }
        underline(x: 270, to: 1000, y: 270, in: ctx)
        text("Date:", at: CGPoint(x: 1060, y: 260), font: "Helvetica", size: 44, in: ctx)
        underline(x: 1190, to: 1580, y: 270, in: ctx)
        text("Period:", at: CGPoint(x: 1060, y: 340), font: "Helvetica", size: 44, in: ctx)
        underline(x: 1230, to: 1580, y: 350, in: ctx)
        if let n = name {
            text(n, at: CGPoint(x: 300, y: 250), font: "BradleyHandITCTT-Bold", size: 60, in: ctx)  // handwriting-like
            text("11/7", at: CGPoint(x: 1230, y: 250), font: "BradleyHandITCTT-Bold", size: 56, in: ctx)
        }
    } else if let n = name {      // no label: name just written at the top
        text(n, at: CGPoint(x: 900, y: 140), font: "BradleyHandITCTT-Bold", size: 60, in: ctx)
    }
    for (i, l) in (body + extra).enumerated() {
        text(l, at: CGPoint(x: 120, y: 520 + CGFloat(i) * 150), font: "Helvetica", size: 40, in: ctx)
    }
}

func png(_ name: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx)
    let url = outDir.appendingPathComponent(name)
    let type: UTType = name.hasSuffix(".jpg") ? .jpeg : .png
    let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}

// A "who said it" table: handwritten speaker names in a column, no label to key on.
func tablePage(_ ctx: CGContext) {
    page(ctx, name: "Marcus Delgado", extra: [])
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H - 480))   // clear the quiz body
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    text("Quote", at: CGPoint(x: 120, y: 520), font: "Helvetica-Bold", size: 40, in: ctx)
    text("Who said it?", at: CGPoint(x: 1100, y: 520), font: "Helvetica-Bold", size: 40, in: ctx)
    let rows = [("The weather will grow cold before the mark is reached.", "Atticus"),
                ("We should grace the table with a good story.", "Mrs. Dubose"),
                ("Hope is the thing with feathers.", "Scout Finch"),
                ("Please read the next chapter and answer the questions.", "Mr. Baker")]
    for (i, r) in rows.enumerated() {
        let y = 620 + CGFloat(i) * 170
        text(r.0, at: CGPoint(x: 120, y: y), font: "Helvetica", size: 34, in: ctx)
        text(r.1, at: CGPoint(x: 1120, y: y - 10), font: "BradleyHandITCTT-Bold", size: 56, in: ctx)
        underline(x: 100, to: 1600, y: y + 40, in: ctx)
    }
}
png("quiz_table.png") { tablePage($0) }

// A name that wraps: first name on the Name line, last name on the line below, Period label on that row.
png("quiz_twoline.png") { ctx in
    page(ctx, name: "Jordan")
    text("Whitfield", at: CGPoint(x: 300, y: 335), font: "BradleyHandITCTT-Bold", size: 60, in: ctx)
    underline(x: 270, to: 1000, y: 350, in: ctx)
}
png("quiz_png.png")      { page($0, name: "Jordan Whitfield") }
png("quiz_jpg.jpg")      { page($0, name: "Priya Raman") }
png("quiz_nolabel.png")  { page($0, name: "Tomas Okafor", labels: false) }

// Two-page PDF with a REAL text layer (to prove flattening removes it). Page 2 mentions a roster name.
var box = CGRect(x: 0, y: 0, width: W * 0.36, height: H * 0.36)      // 612 x 792 pt
let pdf = CGContext(outDir.appendingPathComponent("quiz_two_page.pdf") as CFURL, mediaBox: &box, nil)!
for p in 0..<2 {
    pdf.beginPDFPage(nil); pdf.scaleBy(x: 0.36, y: 0.36)
    page(pdf, name: p == 0 ? "Lena Hoffmann" : nil, labels: p == 0,
         extra: p == 0 ? [] : ["Group work: Priya Raman and Jordan Whitfield compared answers."])
    pdf.endPDFPage()
}
pdf.closePDF()
// "Name" with no colon, a long loopy name running far right, and a printed Topic line right under it.
png("quiz_nocolon.png") { ctx in
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(2)
    text("Name", at: CGPoint(x: 120, y: 250), font: "Helvetica-Bold", size: 44, in: ctx)
    text("Cooper-McAllister", at: CGPoint(x: 260, y: 240), font: "BradleyHandITCTT-Bold", size: 78, in: ctx)
    underline(x: 110, to: 1100, y: 285, in: ctx)
    text("Topic: Finding the main idea", at: CGPoint(x: 120, y: 350), font: "Helvetica-Bold", size: 40, in: ctx)
    text("1.  Read the passage and underline the main idea.", at: CGPoint(x: 120, y: 520), font: "Helvetica", size: 40, in: ctx)
}

// A three-page "class set" PDF: front (named), back (seminar table, NO Name: label), front (named).
// Used to test --scope header: only the top of each page should be redacted, never the table body.
var cbox = CGRect(x: 0, y: 0, width: W * 0.36, height: H * 0.36)
let cls = CGContext(outDir.appendingPathComponent("quiz_class.pdf") as CFURL, mediaBox: &cbox, nil)!
for n in 0..<3 {
    cls.beginPDFPage(nil); cls.scaleBy(x: 0.36, y: 0.36)
    if n == 1 {
        cls.setFillColor(CGColor(gray: 1, alpha: 1)); cls.fill(CGRect(x: 0, y: 0, width: W, height: H))
        cls.setFillColor(CGColor(gray: 0.1, alpha: 1)); cls.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); cls.setLineWidth(2)
        text("Seminar notes", at: CGPoint(x: 120, y: 130), font: "Helvetica-Bold", size: 56, in: cls)
        text("Who said it?", at: CGPoint(x: 120, y: 520), font: "Helvetica-Bold", size: 40, in: cls)
        for (i, who) in ["Atticus", "Scout Finch", "Mr. Baker"].enumerated() {
            text(who, at: CGPoint(x: 120, y: 640 + CGFloat(i) * 160), font: "BradleyHandITCTT-Bold", size: 56, in: cls)
        }
    } else {
        page(cls, name: n == 0 ? "Lena Hoffmann" : "Tomas Okafor")
    }
    cls.endPDFPage()
}
cls.closePDF()
// Five fronts; on page 3 the printed "Name:" is absent (as if OCR had missed it) but the name is in the same place.
var ibox = CGRect(x: 0, y: 0, width: W * 0.36, height: H * 0.36)
let inf = CGContext(outDir.appendingPathComponent("quiz_class_infer.pdf") as CFURL, mediaBox: &ibox, nil)!
for (n, who) in ["Lena Hoffmann", "Tomas Okafor", "Priya Raman", "Marcus Delgado", "Dana Kowalski"].enumerated() {
    inf.beginPDFPage(nil); inf.scaleBy(x: 0.36, y: 0.36)
    page(inf, name: who, labelText: n != 2)
    inf.endPDFPage()
}
inf.closePDF()
print("wrote samples to \(outDir.path)")
