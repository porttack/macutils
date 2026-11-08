// Makes fake Socratic seminar PDFs (invented names) for testing socratic_summary.
// Run:  swift make_test_sheets.swift
//   test_sheets.pdf  6 pages, each page has a before AND an after part
//   test_start.pdf   6 pages, starting responses only (a different question, different order)
//   test_after.pdf   6 pages, after-seminar reflections only (different order, one name misspelled)
import Foundation
import CoreGraphics
import CoreText

let W = 1700.0, H = 2200.0

func text(_ s: String, x: CGFloat, y: CGFloat, font: String, size: CGFloat, in ctx: CGContext) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: H - y)
    CTLineDraw(line, ctx)
}

struct Sheet { let name: String; let before: [String]; let after: [String]; let notes: [String] }

let sheets = [
    Sheet(name: "Dana Kowalski",
          before: ["I think breaking a rule is okay if the rule is unfair,", "because rules should protect people not hurt them."],
          after: ["I still think unfair rules can be broken but Priya made", "me see that you should try to change the rule first."],
          notes: ["Most people talked at the start. A few kids stayed quiet."]),
    Sheet(name: "Priya Raman",
          before: ["Rules are there to keep everyone safe so you", "should almost never break them."],
          after: ["Now I think intent matters. Someone who breaks a", "rule to help another person is different."],
          notes: ["The talk got better when we used the text as evidence."]),
    Sheet(name: "Marcus Delgado",
          before: ["It depends on why you break the rule. If you are", "trying to help someone it can be okay."],
          after: ["My idea did not change. Intent matters most and", "Dana and Priya both said something like that."],
          notes: ["We went off topic one time but came back."]),
    Sheet(name: "Lena Hoffmann",
          before: ["I do not think you should break rules because", "then nobody knows what to expect."],
          after: ["I changed my mind a little. Some rules protect", "people so breaking them can be right."],
          notes: ["Everyone listened to each other, it was calm."]),
    Sheet(name: "Tomas Okafor",
          before: ["Rules protect people. Breaking them is wrong", "unless the rule is hurting someone."],
          after: ["I agree with Marcus that intent matters. I would", "still try to change the rule the right way first."],
          notes: ["Two people did most of the talking."]),
    Sheet(name: "Jordan Whitfield",
          before: ["I think it is fine to break a rule if nobody", "gets hurt and it is fair."],
          after: ["Same as before. Fairness is the main thing for me."],
          notes: ["It was fun. I wish we had more time."]),
]

let dir = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent()

func drawPage(_ pdf: CGContext, name: String, parts: [(String, [String])]) {
    pdf.beginPDFPage(nil); pdf.scaleBy(x: 0.36, y: 0.36)
    pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(CGRect(x: 0, y: 0, width: W, height: H))
    pdf.setFillColor(CGColor(gray: 0.1, alpha: 1))
    text("Socratic Seminar Reflection", x: 120, y: 130, font: "Helvetica-Bold", size: 56, in: pdf)
    text("Name:", x: 120, y: 260, font: "Helvetica", size: 44, in: pdf)
    text(name, x: 290, y: 255, font: "BradleyHandITCTT-Bold", size: 60, in: pdf)
    var y: CGFloat = 420
    for (title, lines) in parts {
        text(title, x: 120, y: y, font: "Helvetica-Bold", size: 38, in: pdf); y += 90
        for l in lines { text(l, x: 140, y: y, font: "BradleyHandITCTT-Bold", size: 50, in: pdf); y += 85 }
        y += 120
    }
    pdf.endPDFPage()
}

func makePDF(_ file: String, _ pages: [(String, [(String, [String])])]) {
    var box = CGRect(x: 0, y: 0, width: W * 0.36, height: H * 0.36)
    let url = dir.appendingPathComponent(file)
    let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
    for p in pages { drawPage(pdf, name: p.0, parts: p.1) }
    pdf.closePDF()
    print("wrote \(url.path)")
}

let qBefore = "Before the seminar: what is your answer to the question?"
let qAfter = "After the seminar: has your thinking changed?"
let qNotes = "Notes on how the discussion went:"

// 1. Both parts on every page
makePDF("test_sheets.pdf", sheets.map { ($0.name, [(qBefore, $0.before), (qAfter, $0.after), (qNotes, $0.notes)]) })

// 2. Starting responses only, in a different order
let startOrder = [3, 0, 5, 1, 4, 2]
makePDF("test_start.pdf", startOrder.map { i in
    (sheets[i].name, [("Start of the seminar: what do you think about the question?", sheets[i].before)])
})

// 3. After reflections only, shuffled again; one name misspelled so it will not match
let afterOrder = [1, 4, 2, 5, 0, 3]
makePDF("test_after.pdf", afterOrder.map { i in
    let name = sheets[i].name == "Lena Hoffmann" ? "Lena Hofman" : sheets[i].name
    return (name, [("After the discussion: what changed or stayed the same for you?", sheets[i].after),
                   (qNotes, sheets[i].notes)])
})
