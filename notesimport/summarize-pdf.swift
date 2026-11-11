// summarize-pdf: print a short Apple Intelligence summary of a PDF's text.
//
// Build and install (installs to /usr/local/bin, which is already on PATH;
// Homebrew on Apple silicon uses /opt/homebrew, so this folder stays ours):
//   swiftc summarize-pdf.swift -o summarize-pdf
//   sudo install -m 755 summarize-pdf /usr/local/bin/
// The "Import Scans to Notes" AppleScript calls /usr/local/bin/summarize-pdf by full path,
// because do shell script uses a minimal PATH. Update its summaryTool property if this moves.
// Rebuild after major macOS or Xcode updates.
//
// Requires: Apple silicon Mac, macOS 26+, Apple Intelligence on, Xcode or Command Line Tools.
// Usage:  summarize-pdf [--dry-run] [--always-add-summary] [--no-cleanup] file.pdf
//   -n, --dry-run             do the OCR and summary, report what would change, write nothing
//   -s, --always-add-summary  also store the summary in PDFs that already have text
//                             (this rewrites the file, so its modification date changes)
//   -C, --no-cleanup          don't clean up black-and-white pages (see below)
//
// Image-only scans (no text layer) are OCR'd on-device with the Vision framework first.
// The OCR text is written back into the PDF as an invisible, searchable text layer
// (so Spotlight, Preview, and Notes can find words in it), and since the file is being
// rewritten anyway, the summary goes into the PDF's Subject field (Preview: Tools > Show
// Inspector; Spotlight indexes it). PDFs that already have text are left untouched unless
// --always-add-summary is given. Page images are unchanged, the creation date is kept, and
// the original is only replaced after the new PDF passes a sanity check.
// Set addTextLayer to false to never add text layers.
// When an image-only scan is rewritten, each page that is mostly black and white (almost no
// color, mostly light paper and dark ink) is also cleaned up: converted to grayscale, with the
// paper brightened to white and the ink darkened. Color pages and photos are left as they are.
// Pass --no-cleanup (or set cleanUpBlackAndWhite to false) to keep the page images untouched.
// Exit codes: 0 = success, 1 = no text in PDF even after OCR, 2 = model error or still too long,
//             3 = model declined even with permissive guardrails,
//             4 = language not recognized (e.g., numbers-only receipt),
//             5 = timed out downloading an iCloud-only file, 64 = usage error
// Progress notes go to stderr (prefixed DEBUG:), so only the summary appears on stdout.
// If the default guardrails decline a document (e.g., a tax return), the summary from the
// permissive fallback is printed with the prefix "Potentially sensitive: ".
// Everything runs on-device; nothing is sent off the Mac.

import Foundation
import PDFKit
import Vision
import AppKit
import CoreText
import FoundationModels

// The on-device model has roughly a 4,096-token window shared by instructions,
// schema, document, and reply. ~2,500 words leaves room for everything else.
let maxWords = 2500
let fallbackCharLimits = [6000, 3000]   // tried in order if the word budget is still too big
let addTextLayer = true                 // write OCR text back into image-only PDFs (OCRs every page)
let maxOCRPagesForSummary = 5           // the summary only uses the opening pages anyway
let minTextLayerCharacters = 20         // less than this counts as "no text layer"
let cleanUpBlackAndWhite = true         // clean up mostly black-and-white pages (--no-cleanup turns it off)
let maxColorFraction = 0.015            // a page is "black and white" if under 1.5% of pixels have color
let maxMidtoneFraction = 0.25           // ...and under 25% are mid-gray (more than that looks like a photo)
let cleanupLongSide = 3300.0            // render cleaned pages up to this many pixels on the long side

let baseInstructions =
    "You summarize scanned personal documents such as bills, letters, forms, tax documents, and receipts."

@Generable
struct ScanSummary {
    @Guide(description: "A 2-3 sentence summary of the document as one plain-text paragraph, with no title, preamble, or formatting")
    var summary: String
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("DEBUG: \(message)\n".utf8))
}

// If the file is an iCloud placeholder (offloaded by Optimize Mac Storage), ask iCloud to
// download it and wait until a local copy exists. Returns false if it times out.
func ensureDownloaded(_ url: URL, timeout: TimeInterval = 120) async -> Bool {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
        return true   // not an iCloud file, nothing to do
    }
    func isLocal(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        status == .current || status == .downloaded
    }
    if isLocal(values.ubiquitousItemDownloadingStatus) { return true }

    log("file is only in iCloud; downloading it first")
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        if isLocal(try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) {
            log("download finished")
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return false
}

// ===== OCR and searchable text layer =====

// One recognized line of text and where it sits on the page (Vision's normalized
// coordinates: 0-1, origin at bottom left, which matches PDF coordinates).
struct OCRLine {
    let text: String
    let box: CGRect
}

// Page size as displayed, accounting for rotation.
func displaySize(of page: PDFPage) -> CGSize {
    let bounds = page.bounds(for: .mediaBox)
    return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
}

// OCR one page with Vision (on-device, same engine as Live Text).
func recognizeLines(on page: PDFPage, pageNumber: Int) -> [OCRLine] {
    // Render at 3x (about 216 dpi) so small receipt text is readable
    let size = displaySize(of: page)
    let renderSize = CGSize(width: size.width * 3, height: size.height * 3)
    guard let cgImage = page.thumbnail(of: renderSize, for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        log("OCR failed on page \(pageNumber): \(error)")
        return []
    }
    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return OCRLine(text: text, box: observation.boundingBox)
    }
}

// Draw each OCR line as invisible text, stretched to cover the words it came from,
// so searching and selecting text lines up with the image.
func drawInvisibleText(_ lines: [OCRLine], in ctx: CGContext, pageSize: CGSize) {
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    for line in lines where !line.text.isEmpty {
        let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                          width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
        let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height, 1), nil)
        let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard width > 0 else { continue }
        ctx.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(width), y: 1)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
        CTLineDraw(ctLine, ctx)
    }
    ctx.restoreGState()
}

// ===== Black-and-white cleanup =====

// Render a page into a bitmap context of the given pixel width (gray or RGB), on white.
func renderPage(_ page: PDFPage, pixelWidth: Int, gray: Bool) -> CGContext? {
    let size = displaySize(of: page)
    guard size.width > 0, size.height > 0 else { return nil }
    let width = max(pixelWidth, 1)
    let height = max(Int((CGFloat(width) * size.height / size.width).rounded()), 1)
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
    page.transform(ctx, for: .mediaBox)
    page.draw(with: .mediaBox, to: ctx)
    return ctx
}

// Pixel width that keeps the long side at or under cleanupLongSide, and at least ~216 dpi.
func cleanupPixelWidth(for page: PDFPage) -> Int {
    let size = displaySize(of: page)
    let scale = min(cleanupLongSide / max(size.width, size.height), 4.0)
    return Int(size.width * max(scale, 3.0))
}

// True if the page is mostly black and white: almost no colored pixels, and mostly light
// paper and dark ink rather than mid-tones (which would be a photo).
func isMostlyBlackAndWhite(_ page: PDFPage) -> Bool {
    guard let ctx = renderPage(page, pixelWidth: 500, gray: false), let data = ctx.data else { return false }
    let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
    var colored = 0, midtone = 0
    for y in 0..<ctx.height {
        for x in 0..<ctx.width {
            let p = y * ctx.bytesPerRow + x * 4
            let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
            if max(r, g, b) - min(r, g, b) > 30 { colored += 1 }
            let luma = (r * 3 + g * 6 + b) / 10
            if luma > 76 && luma < 178 { midtone += 1 }
        }
    }
    let total = Double(ctx.width * ctx.height)
    return Double(colored) / total < maxColorFraction && Double(midtone) / total < maxMidtoneFraction
}

// Grayscale version of the page with levels adjusted: the paper (found from the brightness
// histogram) becomes white and the darkest ink becomes black.
func cleanedImage(of page: PDFPage) -> CGImage? {
    guard let ctx = renderPage(page, pixelWidth: cleanupPixelWidth(for: page), gray: true),
          let data = ctx.data else { return nil }
    let count = ctx.bytesPerRow * ctx.height
    let pixels = data.bindMemory(to: UInt8.self, capacity: count)

    var histogram = [Int](repeating: 0, count: 256)
    for y in 0..<ctx.height {
        for x in 0..<ctx.width { histogram[Int(pixels[y * ctx.bytesPerRow + x])] += 1 }
    }
    let total = ctx.width * ctx.height
    func percentile(_ fraction: Double) -> Int {
        var running = 0
        for value in 0..<256 {
            running += histogram[value]
            if Double(running) >= Double(total) * fraction { return value }
        }
        return 255
    }
    let black = Double(percentile(0.005))
    let white = max(Double(percentile(0.70)) * 0.96, black + 80)   // a little below paper, so paper clips to pure white
    var lookup = [UInt8](repeating: 0, count: 256)
    for value in 0..<256 {
        let level = min(max((Double(value) - black) / (white - black), 0), 1)
        lookup[value] = UInt8((level * 255).rounded())
    }
    for y in 0..<ctx.height {
        for x in 0..<ctx.width {
            let p = y * ctx.bytesPerRow + x
            pixels[p] = lookup[Int(pixels[p])]
        }
    }
    return ctx.makeImage()
}

// Write a copy of the PDF with the original page images plus the invisible text layer.
func writeSearchablePDF(_ doc: PDFDocument, ocrPages: [[OCRLine]], subject newSubject: String?,
                        cleanUp: Bool, to url: URL) -> Bool {
    var info: [String: Any] = [kCGPDFContextCreator as String: "summarize-pdf (Vision OCR)"]
    let attributes = doc.documentAttributes ?? [:]
    if let title = attributes[PDFDocumentAttribute.titleAttribute] { info[kCGPDFContextTitle as String] = title }
    if let author = attributes[PDFDocumentAttribute.authorAttribute] { info[kCGPDFContextAuthor as String] = author }
    if let subject = attributes[PDFDocumentAttribute.subjectAttribute] { info[kCGPDFContextSubject as String] = subject }
    if let newSubject { info[kCGPDFContextSubject as String] = newSubject }

    guard let ctx = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else { return false }
    for index in 0..<doc.pageCount {
        guard let page = doc.page(at: index) else { continue }
        let size = displaySize(of: page)
        var mediaBox = CGRect(origin: .zero, size: size)
        let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

        if cleanUp, isMostlyBlackAndWhite(page), let image = cleanedImage(of: page) {
            ctx.draw(image, in: mediaBox)
            log("cleaned up black-and-white page \(index + 1)")
        } else {
            ctx.saveGState()
            page.transform(ctx, for: .mediaBox)   // applies the page's rotation
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }

        if index < ocrPages.count {
            drawInvisibleText(ocrPages[index], in: ctx, pageSize: size)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return true
}

// Rewrite the PDF safely: build the new copy beside the original, check it, then swap it in.
// ocrPages != nil adds the invisible text layer; subject != nil stores the summary.
func rewritePDF(_ fileURL: URL, doc: PDFDocument, ocrPages: [[OCRLine]]?, subject: String?, cleanUp: Bool) {
    let fm = FileManager.default
    do {
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: fileURL, create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let tempURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)

        let written: Bool
        if let ocrPages {
            written = writeSearchablePDF(doc, ocrPages: ocrPages, subject: subject, cleanUp: cleanUp, to: tempURL)
        } else {
            var attributes = doc.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.subjectAttribute] = subject
            doc.documentAttributes = attributes
            written = doc.write(to: tempURL)
        }
        guard written else {
            log("could not write the new PDF; original left unchanged")
            return
        }

        // Sanity check before touching the original: same page count, and text if we added it
        guard let check = PDFDocument(url: tempURL), check.pageCount == doc.pageCount else {
            log("new PDF failed its check (page count); original left unchanged")
            return
        }
        if ocrPages != nil,
           (check.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("new PDF failed its check (no text layer); original left unchanged")
            return
        }

        let originalCreation = (try? fm.attributesOfItem(atPath: fileURL.path))?[.creationDate]
        // replaceItemAt keeps the original's Finder tags, permissions, and comments by default
        _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
        if let created = originalCreation {
            try? fm.setAttributes([.creationDate: created], ofItemAtPath: fileURL.path)
        }
        var changes: [String] = []
        if ocrPages != nil { changes.append("added a searchable text layer") }
        if subject != nil { changes.append("stored the summary in the Subject field") }
        log(changes.joined(separator: " and "))
    } catch {
        log("could not rewrite the PDF: \(error); original left unchanged")
    }
}

// First `limit` words of the text, keeping its original spacing and line breaks.
func prefix(_ text: String, words limit: Int) -> String {
    var count = 0
    var end = text.startIndex
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                             options: [.byWords, .substringNotRequired]) { _, range, _, stop in
        count += 1
        end = range.upperBound
        if count >= limit { stop = true }
    }
    return count < limit ? text : String(text[..<end])
}

// Wrap the OCR text in plain English. Receipts and forms are mostly numbers and codes,
// and without some real sentences the model's language check can fail ("Unsupported language").
func makePrompt(_ text: String) -> String {
    "Please summarize the following scanned document. It may be a receipt, bill, form, or letter, "
        + "so the text below may be mostly numbers, abbreviations, and OCR errors.\n\nDocument text:\n"
        + text
}

// Normal path: default guardrails, guided generation (clean output, no preamble).
func summarizeGuided(_ text: String) async throws -> String {
    let session = LanguageModelSession(instructions: baseInstructions)
    let response = try await session.respond(to: makePrompt(text), generating: ScanSummary.self)
    return response.content.summary
}

// Fallback path for documents the default guardrails decline (tax returns, medical bills, etc.).
// Permissive guardrails apply only to plain String output, so the reply gets cleaned up afterward.
func summarizePermissive(_ text: String) async throws -> String {
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    let session = LanguageModelSession(model: model, instructions: baseInstructions +
        " Reply with only a 2-3 sentence summary as one plain-text paragraph: no title, no preamble, no formatting.")
    let response = try await session.respond(to: makePrompt(text))
    return cleanUp(response.content)
}

// Strip chatty lead-ins ("Sure! Here is a summary:"), markdown titles, and bold markers.
func cleanUp(_ reply: String) -> String {
    var lines = reply.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if let first = lines.first, lines.count > 1, first.hasSuffix(":") {
        lines.removeFirst()
    }
    lines.removeAll { ($0.hasPrefix("**") && $0.hasSuffix("**")) || $0.hasPrefix("#") }
    return lines.joined(separator: " ").replacingOccurrences(of: "**", with: "")
}

func summarizeWithFallback(_ text: String) async throws -> String {
    do {
        return try await summarizeGuided(text)
    } catch let error as LanguageModelSession.GenerationError {
        switch error {
        case .refusal, .guardrailViolation:
            log("default guardrails declined (\(error.localizedDescription)); retrying with permissive guardrails")
            // Flag summaries that needed the permissive fallback; this text goes straight into the note
            return "Potentially sensitive: " + (try await summarizePermissive(text))
        default:
            throw error
        }
    }
}

// ===== Main =====

func printUsage() {
    FileHandle.standardError.write(Data("""
        usage: summarize-pdf [--dry-run] [--always-add-summary] [--no-cleanup] file.pdf
          -n, --dry-run             do the OCR and summary, report what would change, write nothing
          -s, --always-add-summary  also store the summary in PDFs that already have text
          -C, --no-cleanup          don't clean up black-and-white pages

        """.utf8))
}

var dryRun = false
var alwaysAddSummary = false
var cleanUpEnabled = cleanUpBlackAndWhite
var paths: [String] = []
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "-n", "--dry-run": dryRun = true
    case "-s", "--always-add-summary": alwaysAddSummary = true
    case "-C", "--no-cleanup": cleanUpEnabled = false
    case "-h", "--help": printUsage(); exit(0)
    default:
        if argument.hasPrefix("-") {
            log("unknown option \(argument)")
            printUsage()
            exit(64)
        }
        paths.append(argument)
    }
}
guard paths.count == 1 else {
    printUsage()
    exit(64)
}
if dryRun { log("dry run: nothing will be written") }

let fileURL = URL(fileURLWithPath: paths[0])
guard await ensureDownloaded(fileURL) else {
    log("timed out waiting for iCloud to download the file")
    exit(5)
}
guard let doc = PDFDocument(url: fileURL) else {
    log("could not open the PDF")
    exit(1)
}

var fullText = doc.string ?? ""
var ocrPages: [[OCRLine]]? = nil
if fullText.trimmingCharacters(in: .whitespacesAndNewlines).count < minTextLayerCharacters {
    // OCR every page when adding a text layer; otherwise only what the summary needs
    let pagesToOCR = addTextLayer ? doc.pageCount : min(doc.pageCount, maxOCRPagesForSummary)
    log("no text layer; running OCR on \(pagesToOCR) of \(doc.pageCount) pages")

    var pages: [[OCRLine]] = []
    for index in 0..<pagesToOCR {
        guard let page = doc.page(at: index) else { pages.append([]); continue }
        pages.append(recognizeLines(on: page, pageNumber: index + 1))
    }
    ocrPages = pages

    // Summary text comes from the opening pages only
    fullText = pages.prefix(maxOCRPagesForSummary)
        .map { $0.map(\.text).joined(separator: "\n") }
        .joined(separator: "\n\n")
}
guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    log("no text found, even after OCR")
    exit(1)
}

// Build the list of attempts: word budget first, then shorter character cutoffs
var attempts = [prefix(fullText, words: maxWords)]
for limit in fallbackCharLimits where limit < attempts.last!.count {
    attempts.append(String(fullText.prefix(limit)))
}

log("PDF text: \(fullText.count) characters")

var summary: String? = nil
var failureCode: Int32 = 2
var failureMessage = "still too long after all fallbacks"
summaryLoop: for (number, text) in attempts.enumerated() {
    do {
        summary = try await summarizeWithFallback(text)
        log("attempt \(number + 1) succeeded with \(text.count) characters")
        break summaryLoop
    } catch let error as LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize:
            log("attempt \(number + 1) too long at \(text.count) characters, trying shorter")
            continue summaryLoop
        case .refusal, .guardrailViolation:
            (failureCode, failureMessage) = (3, "model declined to summarize this document: \(error.localizedDescription)")
        case .unsupportedLanguageOrLocale:
            (failureCode, failureMessage) = (4, "model could not identify the document's language (often a numbers-only receipt or poor OCR)")
        default:
            (failureCode, failureMessage) = (2, "model error: \(error)")
        }
        break summaryLoop
    } catch {
        (failureCode, failureMessage) = (2, "error: \(error)")
        break summaryLoop
    }
}
if summary == nil { log(failureMessage) }

// Decide what to write back into the PDF:
// - an image-only scan gets the OCR text layer, plus the summary since we're rewriting anyway
// - a PDF that already has text is left alone unless --always-add-summary was given
let textLayerPages = (addTextLayer && (ocrPages?.contains { !$0.isEmpty } ?? false)) ? ocrPages : nil
let subjectToStore = (textLayerPages != nil || alwaysAddSummary) ? summary : nil

if textLayerPages != nil || subjectToStore != nil {
    if dryRun {
        var changes: [String] = []
        if let pages = textLayerPages { changes.append("add a searchable text layer to \(pages.count) pages") }
        if textLayerPages != nil, cleanUpEnabled {
            let bw = (0..<doc.pageCount).filter { doc.page(at: $0).map(isMostlyBlackAndWhite) ?? false }.count
            if bw > 0 { changes.append("clean up \(bw) black-and-white page\(bw == 1 ? "" : "s")") }
        }
        if subjectToStore != nil { changes.append("store the summary in the Subject field") }
        log("dry run: would " + changes.joined(separator: " and ") + " (creation date kept)")
    } else {
        rewritePDF(fileURL, doc: doc, ocrPages: textLayerPages, subject: subjectToStore, cleanUp: cleanUpEnabled)
    }
} else {
    log(dryRun ? "dry run: would leave the PDF unchanged" : "PDF left unchanged")
}

guard let finalSummary = summary else { exit(failureCode) }
print(finalSummary)
exit(0)
