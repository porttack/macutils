// socratic_summary: summarize scanned Socratic seminar work, entirely on this Mac.
//
// Give it one PDF per class (handwritten student sheets) and, optionally, the lesson plan. It writes
// a Markdown summary of how the seminar went, where students started and ended up, what ideas were
// shared, and how well the class met the lesson's goals. Names are hidden in the body ("Student 3");
// a private student key at the end maps numbers back to names (--no-key to omit it).
//
// Build and install:
//   swiftc -O -parse-as-library socratic_summary.swift -o socratic_summary
//   sudo install -m 755 socratic_summary /usr/local/bin/
//
// Requires Ollama running locally (https://ollama.com) with these models pulled:
//   ollama pull qwen3-vl:8b-instruct   # reads handwriting (a "thinking" build is far too slow)
//   ollama pull gemma2:27b             # groups ideas and writes the summary
//   ollama pull llama3.1:8b            # second summary model, for comparison
// Nothing leaves the Mac: the only network traffic is to http://localhost:11434.
//
// Usage:  socratic_summary [options] class.pdf [more.pdf ...]
//   --class LABEL             name this class/period (default: the PDF's file name)
//   --lesson PATH             lesson plan or kit (.md .txt .html .rtf .docx .pdf), or a folder of them.
//                             Repeatable. Gives the model the question, positions and goals.
//   --position TEXT           set the lesson's positions yourself instead of trusting the digest
//                             (repeat once per position, e.g. --position "Buy it" --position "Don't")
//   --names                   show student names in the body (default: Student 1, 2, ...)
//   --no-key                  don't append the private student key (number -> name) to the summary
//   --model NAME              reader model (default qwen3-vl:8b-instruct)
//   --summary-model A[,B]     model(s) that group ideas and write the summary. Several models each
//                             write their own summary file from the same reading, so you can compare.
//                             Default: gemma2:27b (its themes were about the students' reasons; llama3.1:8b's
//                             were position-like and contradicted the circled counts). To compare: gemma2:27b,llama3.1:8b
//   --reader vlm|vision       how handwriting becomes text. vlm (default): a vision model looks at each
//                             page. vision: Apple's on-device OCR, then a text model (faster, weaker
//                             on messy handwriting).
//   --output FILE             summary path (default: <class>_summary.md in this folder)
//   --data FILE               detail data path (default: <class>.data.json)
//   --stdout                  also print the first summary to the screen
//   --resume                  continue an interrupted read from the data file
//   --from-notes FILE         skip reading; summarize saved data. Repeat to merge classes.
//   --pages-per-student N     pages per sheet (default 1: each page stands alone). An unnamed page that
//                             follows a student's page and prints different text from the other pages
//                             (so it looks like a back side, not another copy of the same form) joins that student
//   --no-attach-backs         count every unnamed page as its own student
//   --one-student-per-pdf     treat each whole PDF as one sheet
//   --topic TEXT              the seminar question, if you aren't giving a --lesson
//   --strip-names             leave names out of the data file
//   --max-pages N             only read the first N sheets (to try a reader)
//   --skip-pages N            skip the first N sheets (with --max-pages, tries a page in the middle)
//   --read-only               read the pages and save the data file, then stop (no summary)
//   --reclassify              with --from-notes: redo the analysis (fields, positions, goal ratings) from the
//                             saved transcripts, text only, no re-reading. Use it to try a rubric change.
//   --ctx N                   context window for reading calls (default 8192)
//   --image-side PX           longest side of the page image sent to the reader (default 1800)
//   --timeout SECONDS         give up on reading one page after this long (default 300)
//
// How it works:
//   1. The lesson (if given) is distilled once into a brief: question, positions, goals.
//   2. Each page is TRANSCRIBED by the vision model: name, and the handwriting verbatim with the printed
//      prompts in [brackets]. A second, text-only step then derives starting view, ending position,
//      reflection, ideas, notes on the discussion, which lesson position the student held at start and
//      end, and a specific/vague/none rating for each lesson goal. (Asking the vision model for all of
//      that at once made it read the name and leave the rest empty.)
//   3. Records are saved to the data file as they are read.
//   4. Counts (positions, movement, goal evidence) are computed here in code and shown in tables.
//      The model groups free-text ideas into themes and writes the narrative in words (no digits,
//      so it can't misquote a count). There is no grade: goals are listed as what went well,
//      what is coming along, and where there is room to grow.
//
// Exit codes: 0 = success, 1 = nothing usable read, 2 = model error, 64 = usage error,
//             69 = Ollama not running or a model is missing. Progress goes to stderr (DEBUG: ...).

import Foundation
import PDFKit
import AppKit
import Vision

// MARK: - Settings

/// How handwriting is turned into text.
enum Reader: String {
    case vlm      // a local vision-language model looks at the page image
    case vision   // Apple's on-device Vision OCR, then a text model structures it
}

struct Settings {
    var showNames = false
    var includeKey = true
    var pagesPerStudent = 1
    var onePerPDF = false
    var attachBacks = true
    var topic: String?
    var model = "qwen3-vl:8b-instruct"
    var summaryModels = ["gemma2:27b"]
    var reader = Reader.vlm
    var outputPath: String?
    var notesPath: String?
    var notesInPaths: [String] = []
    var classLabel: String?
    var lessonPaths: [String] = []
    var positionOverride: [String] = []
    var toStdout = false
    var stripNames = false
    var resume = false
    var maxPages: Int?
    var files: [String] = []
    var readTimeout = 300             // seconds for one page-reading call
    var readCtx = 8192                // context window for reading calls
    var skipPages = 0
    var readOnly = false
    var reclassify = false
    let summaryTimeout = 420          // seconds for one grouping/writing call (gemma2:27b needs about a minute)
    let chatURL = URL(string: "http://localhost:11434/api/chat")!   // local only, by design
    let tagsURL = URL(string: "http://localhost:11434/api/tags")!
    var maxImageSide = 1800.0
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("DEBUG: \(message)\n".utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("socratic_summary: \(message)\n".utf8))
    exit(code)
}

func parseArguments() -> Settings {
    var s = Settings()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(for flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value", code: 64) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--names": s.showNames = true
        case "--no-key": s.includeKey = false
        case "--one-student-per-pdf": s.onePerPDF = true
        case "--no-attach-backs": s.attachBacks = false
        case "--stdout": s.toStdout = true
        case "--strip-names": s.stripNames = true
        case "--resume": s.resume = true
        case "--pages-per-student":
            guard let n = Int(value(for: a)), n >= 1 else { fail("--pages-per-student must be 1 or more", code: 64) }
            s.pagesPerStudent = n
        case "--topic": s.topic = value(for: a)
        case "--class": s.classLabel = value(for: a)
        case "--lesson": s.lessonPaths.append(value(for: a))
        case "--position": s.positionOverride.append(value(for: a))
        case "--model": s.model = value(for: a)
        case "--summary-model":
            s.summaryModels = value(for: a).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if s.summaryModels.isEmpty { fail("--summary-model needs at least one model", code: 64) }
        case "--reader":
            guard let r = Reader(rawValue: value(for: a)) else { fail("--reader must be vlm or vision", code: 64) }
            s.reader = r
        case "--output": s.outputPath = value(for: a)
        case "--data", "--save-notes": s.notesPath = value(for: a)
        case "--from-notes": s.notesInPaths.append(value(for: a))
        case "--max-pages":
            guard let n = Int(value(for: a)), n >= 1 else { fail("--max-pages must be 1 or more", code: 64) }
            s.maxPages = n
        case "--ctx":
            guard let n = Int(value(for: a)), n >= 2048 else { fail("--ctx must be at least 2048", code: 64) }
            s.readCtx = n
        case "--image-side":
            guard let n = Double(value(for: a)), n >= 600 else { fail("--image-side is in pixels, at least 600", code: 64) }
            s.maxImageSide = n
        case "--skip-pages":
            guard let n = Int(value(for: a)), n >= 0 else { fail("--skip-pages must be 0 or more", code: 64) }
            s.skipPages = n
        case "--read-only": s.readOnly = true
        case "--reclassify": s.reclassify = true
        case "--timeout":
            guard let n = Int(value(for: a)), n >= 30 else { fail("--timeout is in seconds, at least 30", code: 64) }
            s.readTimeout = n
        case "-h", "--help":
            print("usage: socratic_summary [--class LABEL] [--lesson PATH]... [--position TEXT]... [--names] [--no-key] [--model NAME] [--summary-model A,B] [--reader vlm|vision] [--output FILE] [--data FILE] [--stdout] [--resume] [--from-notes FILE]... [--pages-per-student N] [--no-attach-backs] [--one-student-per-pdf] [--topic TEXT] [--strip-names] [--max-pages N] [--skip-pages N] [--ctx N] [--image-side PX] [--read-only] [--reclassify] [--timeout SECONDS] class.pdf ...")
            exit(0)
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            s.files.append(a)
        }
    }
    if s.files.isEmpty && s.notesInPaths.isEmpty { fail("give at least one PDF (try --help)", code: 64) }
    return s
}

// MARK: - Reading PDFs (one page at a time, so a giant class PDF does not fill memory)

/// A sheet is one or more pages of one PDF. Pages are rendered only when it is time to read them.
struct SheetSpec {
    let source: String
    let doc: PDFDocument
    let pageIndices: [Int]
}

/// What the reader sees for one sheet: page images (vlm) or OCR text (vision).
struct Sheet {
    let images: [String]
    let ocr: String?
}

func displaySize(of page: PDFPage) -> CGSize {
    let b = page.bounds(for: .mediaBox)
    return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

/// Render a page upright at about 200 dpi, no larger than `maxSide` pixels.
func renderPage(_ page: PDFPage, maxSide: Double) -> CGImage? {
    let size = displaySize(of: page)
    let scale = min(200.0 / 72.0, maxSide / Double(max(size.width, size.height)))
    let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    return page.thumbnail(of: pixels, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func jpegBase64(of image: CGImage) -> String? {
    NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])?
        .base64EncodedString()
}

/// Apple Vision OCR (on-device). Text comes back in reading order: lines are grouped into rows by
/// height, and words in a row are separated by wide gaps so table columns stay distinguishable.
func ocrText(of image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }

    struct Piece { let text: String; let box: CGRect }
    let pieces = (request.results ?? []).compactMap { o -> Piece? in
        o.topCandidates(1).first.map { Piece(text: $0.string, box: o.boundingBox) }
    }.sorted { $0.box.midY > $1.box.midY }            // Vision's y grows upward, so this is top-first

    var rows: [[Piece]] = []
    for p in pieces {
        if let first = rows.last?.first, abs(first.box.midY - p.box.midY) < 0.6 * max(first.box.height, p.box.height) {
            rows[rows.count - 1].append(p)
        } else { rows.append([p]) }
    }
    return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "    ") }
        .joined(separator: "\n")
}

func planSheets(_ settings: Settings) -> [SheetSpec] {
    var specs: [SheetSpec] = []
    for path in settings.files {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            log("could not read \(url.lastPathComponent); skipping")
            continue
        }
        let groupSize = settings.onePerPDF ? doc.pageCount : settings.pagesPerStudent
        for start in stride(from: 0, to: doc.pageCount, by: groupSize) {
            specs.append(SheetSpec(source: url.lastPathComponent, doc: doc,
                                   pageIndices: Array(start..<min(start + groupSize, doc.pageCount))))
        }
        log("\(url.lastPathComponent): \(doc.pageCount) page(s)")
    }
    let skipped = Array(specs.dropFirst(settings.skipPages))
    return settings.maxPages.map { Array(skipped.prefix($0)) } ?? skipped
}

func prepare(_ spec: SheetSpec, _ settings: Settings) -> Sheet {
    let maxSide = settings.reader == .vision ? 2600.0 : settings.maxImageSide
    let pages = spec.pageIndices.compactMap { spec.doc.page(at: $0).flatMap { renderPage($0, maxSide: maxSide) } }
    switch settings.reader {
    case .vlm: return Sheet(images: pages.compactMap(jpegBase64), ocr: nil)
    case .vision: return Sheet(images: [], ocr: pages.map(ocrText).joined(separator: "\n--- next page ---\n"))
    }
}

// MARK: - Talking to Ollama (localhost only)

enum ModelError: Error { case notRunning(String), bad(String), timedOut(Int) }

/// Names of the models Ollama has installed, or nil if Ollama isn't reachable.
func installedModels(_ settings: Settings) async -> Set<String>? {
    var request = URLRequest(url: settings.tagsURL, timeoutInterval: 10)
    request.httpMethod = "GET"
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]] else { return nil }
    return Set(models.compactMap { $0["name"] as? String })
}

func isInstalled(_ name: String, in installed: Set<String>) -> Bool {
    installed.contains(name) || installed.contains(name + ":latest")
}

/// One chat request. `schema` forces the reply to be JSON of that shape.
func chat(model: String, system: String, user: String, images: [String] = [], schema: [String: Any],
          settings: Settings, temperature: Double = 0, maxTokens: Int? = nil,
          numCtx: Int = 8192, timeout: Int) async throws -> Data {
    var message: [String: Any] = ["role": "user", "content": user]
    if !images.isEmpty { message["images"] = images }
    var options: [String: Any] = ["temperature": temperature, "num_ctx": numCtx]
    if let maxTokens { options["num_predict"] = maxTokens }       // stops a model stuck in a loop
    if temperature > 0 { options["repeat_penalty"] = 1.15 }         // retries discourage the loop that broke the first try
    let body: [String: Any] = [
        "model": model, "stream": false, "keep_alive": "15m",
        "format": schema, "options": options,
        "messages": [["role": "system", "content": system], message],
    ]
    var request = URLRequest(url: settings.chatURL, timeoutInterval: Double(timeout))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data, response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: request) }
    catch let e as URLError where e.code == .timedOut { throw ModelError.timedOut(timeout) }
    catch { throw ModelError.notRunning("\(error.localizedDescription)") }
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw ModelError.bad("Ollama returned \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = (json["message"] as? [String: Any])?["content"] as? String else {
        throw ModelError.bad("unexpected reply from Ollama")
    }
    return Data(content.utf8)
}

/// Ask for JSON and decode it. If the reply is malformed or cut off (a model stuck in a loop), try
/// again with a little randomness, which usually breaks the loop. `maxTokens` stops runaway output.
func ask<T: Decodable>(_ type: T.Type, model: String, system: String, user: String, images: [String] = [],
                       schema: [String: Any], settings: Settings, maxTokens: Int? = nil,
                       numCtx: Int = 8192, timeout: Int) async throws -> T {
    var lastError: Error = ModelError.bad("no attempt made")
    for temperature in [0.0, 0.3, 0.6] {
        do {
            let data = try await chat(model: model, system: system, user: user, images: images, schema: schema,
                                      settings: settings, temperature: temperature, maxTokens: maxTokens,
                                      numCtx: numCtx, timeout: timeout)
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as ModelError {
            if case .notRunning = e { throw e }
            if case .timedOut = e { throw e }          // retrying would just wait again
            lastError = e
        } catch { lastError = error }
    }
    throw lastError
}

// JSON schema helpers (so the model must answer in a fixed shape)
func str() -> [String: Any] { ["type": "string"] }
func obj(_ props: [String: Any], required: [String]? = nil) -> [String: Any] {
    ["type": "object", "properties": props, "required": required ?? Array(props.keys)]
}
func arr(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
func oneOf(_ options: [String]) -> [String: Any] { ["type": "string", "enum": options] }

// MARK: - The lesson

struct Goal: Codable { var number: Int; var text: String; var meets_when: String }

/// What the program needs to know about the lesson, distilled once from the teacher's own files.
struct LessonBrief: Codable {
    var question: String
    var positions: [String]
    var goals: [Goal]
    var summary: String
}

let briefSchema = obj([
    "question": str(), "positions": arr(str()),
    "goals": arr(obj(["number": ["type": "integer"], "text": str(), "meets_when": str()])),
    "summary": str(),
])

/// Strip front matter, scripts, styles, template tags, HTML and link syntax from Markdown/HTML.
func cleanMarkup(_ raw: String) -> String {
    var t = raw
    if t.hasPrefix("---"), let end = t.range(of: "\n---", range: t.index(t.startIndex, offsetBy: 3)..<t.endIndex) {
        t = String(t[end.upperBound...])
    }
    for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "\\{%[\\s\\S]*?%\\}", "\\{\\{[\\s\\S]*?\\}\\}", "<[^>]+>"] {
        t = t.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    return t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
}

/// Keep the sections that matter for goals and evidence in full, and only the start of the others.
func trimLesson(_ text: String, maxWords: Int) -> String {
    let important = try! NSRegularExpression(
        pattern: "goal|objective|evidence|assess|question|position|decision|learning|ticket|handout|exit|entry|format|glance",
        options: .caseInsensitive)
    var sections: [(heading: String, lines: [String])] = [("", [])]
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("#") { sections.append((line, [])) } else { sections[sections.count - 1].lines.append(line) }
    }
    var out: [String] = []
    var budget = maxWords
    for (i, sec) in sections.enumerated() {
        let isImportant = i > 0 && important.firstMatch(in: sec.heading, range: NSRange(sec.heading.startIndex..., in: sec.heading)) != nil
        var cap = min(i == 0 ? 450 : (isImportant ? 900 : 200), budget)
        guard cap > 0 else { break }
        var kept: [String] = []
        for line in sec.lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let n = line.split(whereSeparator: \.isWhitespace).count
            if n > cap { break }
            kept.append(line); cap -= n; budget -= n
        }
        if !sec.heading.isEmpty || !kept.isEmpty { out.append(sec.heading + "\n" + kept.joined(separator: "\n")) }
    }
    return out.joined(separator: "\n\n")
}

func plainText(of url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "md", "markdown", "txt", "html", "htm":
        return cleanMarkup((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    case "pdf":
        return PDFDocument(url: url)?.string ?? ""
    case "rtf", "docx", "doc":
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string) ?? ""
    default:
        return ""
    }
}

/// Gather lesson text from files and folders.
func lessonText(_ paths: [String]) -> String {
    var parts: [String] = []
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            fail("lesson path not found: \(path)", code: 64)
        }
        let files = isDir.boolValue
            ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            : [url]
        for f in files {
            let text = trimLesson(plainText(of: f), maxWords: 2600)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("=== \(f.lastPathComponent) ===\n\(text)")
            }
        }
    }
    return parts.joined(separator: "\n\n")
}

func makeBrief(_ text: String, _ settings: Settings) async throws -> LessonBrief {
    let system = """
    You are given a teacher's lesson plan for a Socratic seminar, and possibly a facilitation kit. Extract:
    - question: the central question students discuss, in one sentence.
    - positions: the distinct positions students can take on that question, as short labels exactly as the \
    lesson words them. Empty list if the lesson defines none.
    - goals: the lesson's learning goals, numbered as in the lesson. For each, meets_when says what meeting \
    the goal looks like in student work, taken from the lesson's evidence or assessment criteria if it gives \
    them, otherwise inferred briefly.
    - summary: under 150 words on how the seminar runs and what students write (for example entry ticket, \
    observer organizer, exit ticket, and what each asks).
    Use only what the lesson says.
    """
    return try await ask(LessonBrief.self, model: settings.model, system: system, user: text,
                         schema: briefSchema, settings: settings, maxTokens: 2500,
                         numCtx: 16384, timeout: settings.summaryTimeout)
}

/// The lesson's question, summary and goals, as text for the narrative prompt.
func lessonBlock(_ b: LessonBrief?) -> String {
    guard let b else { return "" }
    var t = "LESSON: \(b.question)\n\(b.summary)\n"
    if !b.goals.isEmpty { t += "GOALS:\n" + b.goals.map { "\($0.number). \($0.text)" }.joined(separator: "\n") + "\n" }
    return t
}

// MARK: - Step 1: read each page

struct GoalEvidence: Codable { var goal: Int; var level: String; var evidence: String }

struct SheetNotes: Codable {
    var student_name: String
    var legible: Bool
    var before: String            // starting view (may be described in hindsight on an exit page)
    var after: String             // position at the end: their answer to the main question now
    var reflection: String        // how/why their thinking changed, and what influenced it
    var ideas: [String]
    var change_in_thinking: String
    var discussion_notes: String
    var handwriting: String = ""          // verbatim transcript of the handwriting, with the printed prompts in [brackets]
    var start_position: String? = nil     // one of the lesson's positions, filled in by the classify step
    var end_position: String? = nil
    var goal_evidence: [GoalEvidence]? = nil
    var positions_marked: [String]? = nil  // which printed options the student circled or marked (read from the image)
    var form_text: String? = nil           // Apple OCR of the page: reliable for the printed form, used only to tell fronts from backs

    enum CodingKeys: String, CodingKey {
        case student_name, legible, before, after, reflection, ideas, change_in_thinking, discussion_notes
        case handwriting, start_position, end_position, goal_evidence, positions_marked, form_text
    }
}

extension SheetNotes {
    /// Older saved files lack the newer fields; treat them as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        student_name = try c.decode(String.self, forKey: .student_name)
        legible = try c.decode(Bool.self, forKey: .legible)
        before = try c.decode(String.self, forKey: .before)
        after = try c.decode(String.self, forKey: .after)
        reflection = try c.decodeIfPresent(String.self, forKey: .reflection) ?? ""
        ideas = try c.decode([String].self, forKey: .ideas)
        change_in_thinking = try c.decode(String.self, forKey: .change_in_thinking)
        discussion_notes = try c.decode(String.self, forKey: .discussion_notes)
        handwriting = try c.decodeIfPresent(String.self, forKey: .handwriting) ?? ""
        start_position = try c.decodeIfPresent(String.self, forKey: .start_position)
        end_position = try c.decodeIfPresent(String.self, forKey: .end_position)
        goal_evidence = try c.decodeIfPresent([GoalEvidence].self, forKey: .goal_evidence)
        positions_marked = try c.decodeIfPresent([String].self, forKey: .positions_marked)
        form_text = try c.decodeIfPresent(String.self, forKey: .form_text)
    }

    static let empty = SheetNotes(student_name: "", legible: false, before: "", after: "", reflection: "",
                                  ideas: [], change_in_thinking: "", discussion_notes: "")

    /// Did the student write anything? Blank or printed-only pages have no content.
    var hasContent: Bool {
        !before.isEmpty || !after.isEmpty || !reflection.isEmpty || !ideas.isEmpty || !discussion_notes.isEmpty
            || !handwriting.isEmpty || !(positions_marked ?? []).isEmpty
            || (start_position.map(isRealPosition) ?? false) || (end_position.map(isRealPosition) ?? false)
    }
}

func isRealPosition(_ p: String) -> Bool {
    !p.isEmpty && !["unclear", "not stated"].contains(p.lowercased())
}

/// One page's notes plus where it came from.
struct PageRecord: Codable {
    var source: String
    var notes: SheetNotes
}

/// The detail-level data file. Saved as pages are read, so an interruption never loses work, and used
/// to re-run, or to merge several classes, without reading any handwriting again.
struct DataFile: Codable {
    var version = 2
    var classLabel: String
    var created: String
    var reader: String
    var model: String
    var topic: String?
    var lesson: LessonBrief?
    var complete: Bool?
    var sources: [String]?
    var sheetCount: Int?
    var pages: [PageRecord]
}

func saveData(_ file: DataFile, to path: String) -> Bool {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(file) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), options: .atomic)) != nil
}

func loadDataFile(_ path: String) -> DataFile? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return nil }
    return try? JSONDecoder().decode(DataFile.self, from: data)
}

/// What the READER (the vision model) must do: transcribe, nothing else. When it was also asked to extract
/// fields, classify positions and rate goals, it read the name and left everything else empty.
struct Transcription: Codable {
    var student_name: String
    var handwriting: String
}
let transcribeSchema = obj(["student_name": str(), "handwriting": str()])

func transcribePrompt(topic: String?, brief: LessonBrief?) -> String {
    let context = brief.map { "\nThe seminar's central question: \($0.question)\n" }
        ?? topic.map { "\nThe seminar topic: \($0)\n" } ?? ""
    return """
    You are transcribing a scanned, handwritten student page from a Socratic seminar. Record exactly what is \
    on the page. Never invent, correct, or summarize.
    - student_name: the name written on the page ("" if none).
    - handwriting: a faithful transcription of ALL the handwritten text, in reading order. Before each answer, \
    put the printed question or heading it answers in [brackets]. If a printed prompt was left blank, write the \
    bracketed prompt followed by (blank). Do not copy any other printed text.
    \(context)
    """
}

// MARK: - Step 1b: analyze the transcript (text only)

/// Everything derived from the transcript: the free-text fields, plus (with a lesson) goal ratings.
struct Analysis: Codable {
    var student_name: String
    var before: String
    var after: String
    var reflection: String
    var ideas: [String]
    var change_in_thinking: String
    var discussion_notes: String
    var goal_evidence: [GoalEvidence]?
}

func analysisSchema(for brief: LessonBrief?) -> [String: Any] {
    var props: [String: Any] = [
        "student_name": str(), "before": str(), "after": str(), "reflection": str(), "ideas": arr(str()),
        "change_in_thinking": str(), "discussion_notes": str(),
    ]
    if let b = brief, !b.goals.isEmpty {
        props["goal_evidence"] = arr(obj(["goal": ["type": "integer"],
                                          "level": oneOf(["specific", "vague", "none", "not asked"]),
                                          "evidence": str()]))
    }
    return obj(props)
}

func analysisPrompt(topic: String?, brief: LessonBrief?) -> String {
    var t = """
    You are given one student's handwritten answers from a Socratic seminar, as blocks: a printed prompt, then the \
    student's answer ("(blank)" means they left it empty). Record only what the answers say. Quote or closely \
    paraphrase the student's own words, and NEVER add an idea, reason or opinion that is not written there.
    - student_name: the student's name if it appears ("" if none).
    - before: the student's STARTING view on the main question and the reason they give, in their voice. An entry \
    ticket's side and reason go here. "I used to think..." or "At first I believed..." belongs here too.
    - after: their position at the END, after the discussion ("" if the page has none, as an entry ticket does not).
    - reflection: how or why their thinking changed, and what influenced it ("" if the page doesn't say).
    - ideas: one short phrase (under 14 words, using the student's own words) for EACH answered prompt: the question \
    they asked, their reason, their evidence, and any other answer. Skip blank answers. No invented ideas.
    - change_in_thinking: one short sentence on how their thinking changed, or "no change", or "unclear".
    - discussion_notes: anything they wrote about the seminar itself ("" if nothing).

    """
    if let b = brief {
        t += "\nLESSON CONTEXT. Central question: \(b.question)\n\(b.summary)\n"
        if !b.goals.isEmpty {
            t += "- goal_evidence: one entry for EACH goal below. Rate what THIS page shows: \"specific\" (contains the concrete detail the criterion names, such as a cited paragraph, a named rule, or a stated data type; a general opinion without that detail is only \"vague\"), \"vague\" (gestures at it), \"none\" (the page asked for it but the answer is blank or unusable), or \"not asked\" (nothing on this page prompts for it; use this whenever the page simply doesn't ask). Put a short quote in evidence.\nGoals:\n"
            for g in b.goals { t += "  \(g.number). \(g.text) Meeting it looks like: \(g.meets_when)\n" }
        }
    } else if let topic { t += "\nThe seminar topic was: \(topic)\n" }
    return t
}

// MARK: - Cleaning transcripts: printed text repeats on every sheet, handwriting does not

private func normLine(_ l: String) -> String {
    // Digits are dropped on purpose: a printed line like "How sure are you...? __ / 10" has a different handwritten number on every sheet.
    String(l.lowercased().filter { $0.isLetter || $0 == " " }).split(separator: " ").joined(separator: " ")
}

/// Lines (normalized) that appear on more than half of the pages: the printed form. Needs at least 4 pages.
func templateLines(_ transcripts: [String]) -> Set<String> {
    guard transcripts.count >= 4 else { return [] }
    var counts: [String: Int] = [:]
    for t in transcripts {
        for l in Set(t.split(separator: "\n").map { normLine(String($0)) }) where l.count > 2 { counts[l, default: 0] += 1 }
    }
    return Set(counts.filter { $0.value * 2 > transcripts.count }.keys)
}

/// Turn a page's transcript into "printed prompt / student's answer" blocks, dropping the printed form. Falls back
/// to the raw transcript when no numbered prompts are found.
func cleanedQA(_ transcript: String, template: Set<String>) -> String {
    guard !template.isEmpty else { return transcript }
    var blocks: [(prompt: String, answers: [String])] = []
    var leftovers: [String] = []
    for raw in transcript.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let isTemplate = template.contains(normLine(line))
        if isTemplate, let m = line.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
            blocks.append((String(line[m.upperBound...]).prefix(90).description, [])); continue
        }
        if isTemplate { continue }
        if blocks.isEmpty { leftovers.append(line) } else { blocks[blocks.count - 1].answers.append(line) }
    }
    if blocks.isEmpty { return leftovers.joined(separator: "\n") }
    return blocks.enumerated().map { i, b in
        "Prompt \(i + 1): \(b.prompt)\n   answer: \(b.answers.isEmpty ? "(blank)" : b.answers.joined(separator: " / "))"
    }.joined(separator: "\n") + (leftovers.isEmpty ? "" : "\nOther writing: " + leftovers.joined(separator: " / "))
}

private func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        prev = cur
    }
    return prev[b.count]
}

/// Is a model-written phrase made of the student's own words? At least 60% of its longer words must appear in the
/// source text (allowing a one-letter slip). This drops ideas a small model invented.
func isGrounded(_ phrase: String, in source: String) -> Bool {
    let words = phrase.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
    guard !words.isEmpty else { return true }
    let pool = Set(source.lowercased().split { !$0.isLetter }.map(String.init))
    let hits = words.filter { w in pool.contains(w) || pool.contains { $0.first == w.first && abs($0.count - w.count) <= 1 && editDistance($0, w) <= 1 } }
    return Double(hits.count) / Double(words.count) >= 0.6
}

/// Fill a page's fields from its cleaned answers. If the model fails, the page keeps its transcript only.
func analyzed(_ n: SheetNotes, qa: String, brief: LessonBrief?, topic: String?, model: String, settings: Settings) async -> SheetNotes {
    guard !qa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return n }
    do {
        let a = try await ask(Analysis.self, model: model, system: analysisPrompt(topic: topic, brief: brief),
                              user: "Answers:\n\(qa)", schema: analysisSchema(for: brief),
                              settings: settings, maxTokens: 2500, numCtx: 8192, timeout: settings.readTimeout)
        var out = n
        if out.student_name.isEmpty { out.student_name = a.student_name }
        // Only keep what is actually in the student's words.
        func keep(_ s: String) -> String { s.isEmpty || isGrounded(s, in: qa) ? s : "" }
        out.before = keep(a.before); out.after = keep(a.after); out.reflection = keep(a.reflection)
        out.ideas = a.ideas.filter { isGrounded($0, in: qa) }
        out.change_in_thinking = a.change_in_thinking; out.discussion_notes = keep(a.discussion_notes)
        out.goal_evidence = a.goal_evidence
        // Safety net: a small model sometimes returns nothing for a short or faint page that does have answers.
        // Then use the student's own answers, verbatim, so the page is never empty.
        if out.ideas.isEmpty && out.before.isEmpty {
            out.ideas = qa.split(separator: "\n").compactMap { line -> String? in
                guard let r = line.range(of: "answer: ") else { return nil }
                let text = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return text.isEmpty || text == "(blank)" ? nil : String(text.prefix(140))
            }
        }
        return out
    } catch {
        log("analysis of a page failed (\(error)); keeping its transcript only")
        return n
    }
}

/// Second pass over all pages, after reading: remove the printed form, analyze each page, and derive each page's
/// starting position from the options the student marked. Runs from saved transcripts, with no re-reading.
func analyzeAll(_ records: inout [(cls: String, record: PageRecord)], brief: LessonBrief?, topic: String?, settings: Settings) async {
    var templates: [String: Set<String>] = [:]
    for cls in Set(records.map(\.cls)) {
        templates[cls] = templateLines(records.filter { $0.cls == cls }.map { $0.record.notes.handwriting })
    }
    for i in records.indices {
        var n = records[i].record.notes
        // Do not trust the model's own "legible" flag: it called readable pages illegible. A page counts if it has text.
        n.legible = !n.handwriting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if n.legible {
            let qa = cleanedQA(n.handwriting, template: templates[records[i].cls] ?? [])
            n = await analyzed(n, qa: qa, brief: brief, topic: topic, model: settings.model, settings: settings)
            n = fixPhase(n, ocr: n.handwriting)
            if let marks = n.positions_marked {
                n.start_position = marks.count == 1 ? marks[0] : (marks.isEmpty ? "not stated" : "unclear")
            }
        }
        if settings.stripNames { n.student_name = "" }
        records[i].record.notes = n
    }
}

// MARK: - Which printed option is circled? (read from the image, not the transcript)

struct Marks: Codable { var marked: [String] }

/// Find where the lesson's position options are printed, crop the page to that band at high resolution, and ask the
/// vision model which of them the student circled or marked. Returns nil if the options aren't on the page.
func markedPositions(spec: SheetSpec, positions: [String], settings: Settings) async -> [String]? {
    var found: Set<String> = []
    var sawOptions = false
    for idx in spec.pageIndices {
        guard let page = spec.doc.page(at: idx), let small = renderPage(page, maxSide: 1800) else { continue }
        let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
        guard (try? VNImageRequestHandler(cgImage: small).perform([req])) != nil else { continue }
        let squash: (String) -> String = { String($0.lowercased().filter { $0.isLetter }) }
        let wanted = positions.map(squash)
        var area: CGRect?
        for o in req.results ?? [] {
            guard let text = o.topCandidates(1).first?.string else { continue }
            if wanted.contains(where: { squash(text).contains($0) }) { area = area.map { $0.union(o.boundingBox) } ?? o.boundingBox }
        }
        guard let r = area else { continue }
        sawOptions = true
        // Vision's y grows upward. Include the line above ("Circle one...") and a little below.
        let lineH = r.height / CGFloat(max(positions.count, 1))
        let y0 = max(0, r.minY - 0.6 * lineH), y1 = min(1, r.maxY + 1.6 * lineH)
        guard let big = renderPage(page, maxSide: 3300) else { continue }
        let crop = CGRect(x: 0, y: (1 - y1) * CGFloat(big.height), width: CGFloat(big.width), height: (y1 - y0) * CGFloat(big.height))
        guard let piece = big.cropping(to: crop), let jpeg = jpegBase64(of: piece) else { continue }
        let schema = obj(["marked": arr(oneOf(positions))])
        let system = "You look at part of a scanned handout. It prints these options: \(positions.joined(separator: "; ")). The student marked one (sometimes more than one) of them with a circle, oval, underline, check mark, or by scribbling or shading over it. List EVERY printed option that has a pen mark around or on it. An option with no pen mark on or around it must NOT be listed, whatever the student wrote. Return an empty list if none is marked. Use only the pen marks, not the student's writing or reasoning."
        if let m = try? await ask(Marks.self, model: settings.model, system: system, user: "Which options are circled or marked?",
                                  images: [jpeg], schema: schema, settings: settings, maxTokens: 200, timeout: settings.readTimeout) {
            m.marked.forEach { found.insert($0) }
        }
    }
    guard sawOptions else { return nil }
    return positions.filter { found.contains($0) }
}

/// With OCR text, a small text model often files a response under the wrong phase. If the page asks
/// only "before/start" questions, everything written there is a starting view. (Exit pages are left
/// alone: they may legitimately hold both a recalled starting view and an ending position.)
func fixPhase(_ n: SheetNotes, ocr: String) -> SheetNotes {
    func has(_ pattern: String) -> Bool { ocr.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    let asksBefore = has("\\b(before the|prior to|at the start|start of|beginning of|initial|pre-?seminar)\\b")
    let asksAfter = has("\\b(after the|afterward|post-?seminar|following the (seminar|discussion)|at first|used to think|changed)\\b")
    guard asksBefore, !asksAfter else { return n }
    var fixed = n
    let a = n.before, b = n.after
    fixed.before = a.isEmpty ? b : (b.isEmpty || a.contains(b) ? a : (b.contains(a) ? b : a + " " + b))
    fixed.after = ""
    return fixed
}

// MARK: - Step 2: names

/// Labels like "Student 3" (or real names with --names), and a function that rewrites text so
/// every known student name becomes that student's label.
struct Anonymizer {
    var labels: [String]                     // index = student number - 1
    private var replacements: [(from: String, to: String)] = []

    /// `names[i]` is the name written by student number i + 1 ("" if none was readable).
    init(names: [String], showNames: Bool) {
        labels = names.enumerated().map { i, n in showNames && !n.isEmpty ? n : "Student \(i + 1)" }
        for (i, name) in names.enumerated() where !name.isEmpty {
            let words = name.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
            for w in [name] + words {
                replacements.append((w, "Student \(i + 1)"))
                replacements.append((w.uppercased(), "Student \(i + 1)"))
            }
        }
        // Longest names first, so "Maria Gonzalez" is replaced before "Maria".
        replacements.sort { $0.from.count > $1.from.count }
    }

    /// Replace names with labels. A no-op when names are shown.
    func scrub(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        var out = text
        for r in replacements {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: r.from) + "\\b"
            out = out.replacingOccurrences(of: pattern, with: r.to, options: .regularExpression)
        }
        return out
    }
}

// MARK: - Step 3: themes

struct Theme: Codable { var label: String; var summary: String; var students: [Int] }
struct ThemeList: Codable { var themes: [Theme] }
let themeSchema = obj(["themes": arr(obj(["label": str(), "summary": str(), "students": arr(["type": "integer"])]))])

/// Group short statements (id -> text) into themes; counts come from the IDs, checked here.
func findThemes(kind: String, statements: [Int: String], model: String, settings: Settings,
                lesson: LessonBrief?) async throws -> [Theme] {
    guard !statements.isEmpty else { return [] }
    let listing = statements.keys.sorted().map { "\($0): \(statements[$0]!)" }.joined(separator: "\n")
    let system = """
    You group students' statements from a Socratic seminar into themes. Each line is "id: statement". \
    Make 2 to 8 themes. Each theme has a label (under 8 words), a one-sentence summary, and the ids \
    of EVERY student whose statement expresses it. A student may belong to several themes. Every id \
    should appear in at least one theme. A statement may begin with a bracketed [side] the student chose: never \
    contradict it, and group by the student's REASON, not by the side itself. Group by meaning, not wording, and make themes about the \
    CONTENT of what students said (their actual views and ideas), not about the fact that they \
    reflected or changed. Never invent ids or content.
    \(lesson.map { "Seminar question: \($0.question)" } ?? "")
    """
    let reply = try await ask(ThemeList.self, model: model, system: system,
                              user: "Statements (\(kind)):\n\(listing)", schema: themeSchema, settings: settings,
                              maxTokens: 2500, timeout: settings.summaryTimeout)
    return reply.themes.compactMap { t in
        let ids = Array(Set(t.students.filter { statements[$0] != nil })).sorted()
        return ids.isEmpty ? nil : Theme(label: t.label, summary: t.summary, students: ids)
    }.sorted { $0.students.count > $1.students.count }
}

// MARK: - Step 4: narrative

struct Narrative: Codable {
    var seminar_overview: String
    var thinking_shift: String
    var lesson_connection: String
    var class_comparison: String
}
let narrativeSchema = obj(["seminar_overview": str(), "thinking_shift": str(),
                           "lesson_connection": str(), "class_comparison": str()])

// MARK: - Output helpers

/// If the model stopped mid-sentence, cut back to the last complete sentence.
func completeSentences(_ text: String) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = t.last, !".!?\"')".contains(last) else { return t }
    guard let end = t.lastIndex(where: { ".!?".contains($0) }) else { return t }
    return String(t[...end])
}

func slug(_ s: String) -> String {
    let t = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    return t.split(separator: "-").joined(separator: "-")
}

func shorten(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n)).trimmingCharacters(in: .whitespaces) + "…" : s
}

/// Describe a share in words, so the narrative never has numbers to misquote.
func shareWords(_ k: Int, _ n: Int) -> String {
    guard n > 0, k > 0 else { return "none" }
    if k == 1 { return "one student" }
    if k == 2 && n > 4 { return "two students" }
    switch Double(k) / Double(n) {
    case 0.85...: return "nearly all"
    case 0.6..<0.85: return "most"
    case 0.4..<0.6: return "about half"
    case 0.2..<0.4: return "several"
    default: return "a few"
    }
}

/// Reflection or notes that are just filler ("unclear", "none") carry no information.
func isFiller(_ s: String) -> Bool {
    let t = s.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    return t.isEmpty || ["unclear", "none", "no reflection", "na", "nothing", "not stated", "no change", "no answer", "blank"].contains(t)
        || t.hasPrefix("no reflection") || t.hasPrefix("not stated")
}

/// Drop any sentence that contains a digit (the narrative is meant to be in words; exact counts are in tables).
func withoutNumbers(_ text: String) -> String {
    let sentences = text.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) })
    let kept = sentences.filter { !$0.contains(where: \.isNumber) }
    guard !kept.isEmpty else { return text }
    return kept.map { $0.trimmingCharacters(in: .whitespaces) + "." }.joined(separator: " ")
}

func loadRecords(from path: String) -> (records: [(cls: String, record: PageRecord)], lesson: LessonBrief?) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url) else { fail("could not read \(path)", code: 64) }
    let fallbackLabel = url.deletingPathExtension().deletingPathExtension().lastPathComponent
    if let file = try? JSONDecoder().decode(DataFile.self, from: data) {
        return (file.pages.map { (file.classLabel, $0) }, file.lesson)
    }
    if let old = try? JSONDecoder().decode([SheetNotes].self, from: data) {      // earliest format
        return (old.map { (fallbackLabel, PageRecord(source: fallbackLabel, notes: $0)) }, nil)
    }
    fail("\(path) is not a socratic_summary data file", code: 64)
}

/// Per-goal tally of how many students showed specific, vague, or no evidence.
struct GoalTally {
    enum Status: String { case strength = "Strength", developing = "Coming along", roomToGrow = "Room to grow", notCaptured = "Not captured" }
    var goal: Goal
    var specific = 0, vague = 0, none = 0
    var asked: Int { specific + vague + none }
    /// Deliberately generous: partial evidence counts, and a goal the sheets didn't ask about is not a failure.
    var status: Status {
        guard asked > 0 else { return .notCaptured }
        let some = Double(specific + vague) / Double(asked), concrete = Double(specific) / Double(asked)
        if concrete >= 0.5 || (some >= 0.8 && concrete >= 0.25) { return .strength }
        return some >= 0.4 ? .developing : .roomToGrow
    }
}

func goalTable(_ tallies: [GoalTally]) -> String {
    var t = "| Goal | What meeting it looks like | Specific | Vague | None | Where it stands |\n|---|---|---|---|---|---|\n"
    for g in tallies {
        t += "| \(g.goal.number). \(shorten(g.goal.text, 90)) | \(shorten(g.goal.meets_when, 110)) | \(g.specific) | \(g.vague) | \(g.none) | \(g.status.rawValue) |\n"
    }
    return t
}

/// What went well, what is coming along, and where there is room to grow: no grade.
func goalLists(_ tallies: [GoalTally], examples: [Int: [String]]) -> String {
    func line(_ t: GoalTally, detail: Bool) -> String {
        var s = "- **Goal \(t.goal.number)** (\(shorten(t.goal.text, 100))): "
        s += "\(t.specific) of \(t.asked) students gave specific evidence" + (t.vague > 0 ? " and \(t.vague) gave some" : "") + "."
        if detail { s += " Meeting it looks like: \(shorten(t.goal.meets_when, 120))" }
        if let e = examples[t.goal.number]?.first, !detail { s += " _e.g. “\(e)”_" }
        return s
    }
    var out = ""
    func group(_ title: String, _ status: GoalTally.Status, detail: Bool) {
        let items = tallies.filter { $0.status == status }
        if !items.isEmpty { out += "**\(title)**\n\n" + items.map { line($0, detail: detail) }.joined(separator: "\n") + "\n\n" }
    }
    group("What went well", .strength, detail: false)
    group("Coming along", .developing, detail: true)
    group("Room for improvement", .roomToGrow, detail: true)
    let missing = tallies.filter { $0.status == .notCaptured }
    if !missing.isEmpty {
        out += "**Not captured on these sheets** (nothing on the pages asked for it, or it can't be seen on paper)\n\n"
        out += missing.map { "- **Goal \($0.goal.number)** (\(shorten($0.goal.text, 100)))" }.joined(separator: "\n") + "\n\n"
    }
    return out
}

// MARK: - Main

@main
struct SocraticSummary {
    static func main() async {
        let settings = parseArguments()
        let fileStem = settings.files.first.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let thisClass = settings.classLabel ?? fileStem ?? "class"
        let readingNow = settings.notesInPaths.isEmpty
        let textReaderModel = settings.model      // reads page images and analyzes transcripts (already loaded: no model swapping)

        // 0. Check Ollama and the models we need, before doing any slow work.
        guard let installed = await installedModels(settings) else {
            fail("cannot reach Ollama at localhost:11434. Start it with: ollama serve", code: 69)
        }
        var needed = settings.readOnly ? [] : settings.summaryModels
        if readingNow || settings.reclassify { needed.append(settings.model) }
        if !settings.lessonPaths.isEmpty { needed.append(settings.model) }
        for m in Set(needed) where !isInstalled(m, in: installed) {
            fail("model \(m) is not installed. Run: ollama pull \(m)  (or choose another with --model / --summary-model)", code: 69)
        }

        // 1. The lesson brief (once; saved in the data file so merges don't need the files again)
        var lesson: LessonBrief?
        if !settings.lessonPaths.isEmpty {
            let text = lessonText(settings.lessonPaths)
            if text.isEmpty { fail("no readable lesson text in \(settings.lessonPaths.joined(separator: ", "))", code: 64) }
            log("reading the lesson with \(settings.model)")
            do { lesson = try await makeBrief(text, settings) }
            catch ModelError.timedOut(let s) { fail("reading the lesson took longer than \(s)s", code: 2) }
            catch { fail("could not distill the lesson: \(error)", code: 2) }
        }
        if !settings.positionOverride.isEmpty {
            var b = lesson ?? LessonBrief(question: settings.topic ?? "", positions: [], goals: [], summary: "")
            b.positions = settings.positionOverride
            lesson = b
        }
        if let l = lesson { log("lesson: \(l.positions.count) position(s) [\(l.positions.joined(separator: " | "))], \(l.goals.count) goal(s)") }

        // 2. Page records: read the PDFs, or load saved data (several files = merged classes)
        var records: [(cls: String, record: PageRecord)] = []
        var dataPath: String?
        if !readingNow {
            for path in settings.notesInPaths {
                let loaded = loadRecords(from: path)
                records += loaded.records
                if lesson == nil { lesson = loaded.lesson }
            }
            log("loaded \(records.count) page record(s) from \(settings.notesInPaths.count) file(s)")
            if settings.reclassify {
                log("re-analyzing \(records.count) page(s) from their saved transcripts with \(settings.model)")
                await analyzeAll(&records, brief: lesson, topic: settings.topic, settings: settings)
            }
        } else {
            let specs = planSheets(settings)
            if specs.isEmpty { fail("no pages could be read", code: 1) }
            let base = settings.outputPath.map { ($0 as NSString).deletingPathExtension }
                ?? slug(settings.classLabel ?? (settings.files.count > 1 ? "\(fileStem ?? "class")-and-\(settings.files.count - 1)-more" : fileStem ?? "class"))
            let path = settings.notesPath ?? base + ".data.json"
            dataPath = path
            let sources = settings.files.map { URL(fileURLWithPath: $0).lastPathComponent }

            var done = 0
            if settings.resume, let prior = loadDataFile(path), prior.sources == sources {
                records = prior.pages.map { (prior.classLabel, $0) }
                done = records.count
                if lesson == nil { lesson = prior.lesson }
                log("resuming: \(done) of \(specs.count) sheet(s) were already read")
            }
            log("\(specs.count - done) sheet(s) to read with \(settings.reader == .vision ? "Apple Vision OCR + \(textReaderModel)" : settings.model)")
            let started = Date()
            func save(complete: Bool) {
                let file = DataFile(classLabel: thisClass, created: ISO8601DateFormatter().string(from: Date()),
                                    reader: settings.reader.rawValue,
                                    model: settings.reader == .vision ? "Apple Vision + \(textReaderModel)" : settings.model,
                                    topic: settings.topic, lesson: lesson, complete: complete, sources: sources,
                                    sheetCount: specs.count, pages: records.map(\.record))
                _ = saveData(file, to: path)
            }
            for i in done..<specs.count {
                let spec = specs[i]
                let t0 = Date()
                let sheet = prepare(spec, settings)
                var notes = SheetNotes.empty
                do {
                    if let ocr = sheet.ocr {                    // Apple Vision gave us the text already
                        notes.legible = !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        notes.handwriting = ocr
                    } else {                                    // the vision model transcribes the page image
                        let t = try await ask(Transcription.self, model: settings.model,
                                              system: transcribePrompt(topic: settings.topic, brief: lesson),
                                              user: "Transcribe this student's sheet (\(sheet.images.count) page(s)).",
                                              images: sheet.images, schema: transcribeSchema, settings: settings,
                                              maxTokens: 3000, numCtx: settings.readCtx, timeout: settings.readTimeout)
                        notes.student_name = t.student_name; notes.handwriting = t.handwriting
                        notes.legible = !t.handwriting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        // Which printed option did the student circle? Read from the image, in a focused question.
                        if let positions = lesson?.positions, !positions.isEmpty {
                            notes.positions_marked = await markedPositions(spec: spec, positions: positions, settings: settings)
                        }
                    }
                } catch ModelError.notRunning(let why) {
                    save(complete: false)
                    fail("lost contact with Ollama (\(why)). Progress is saved; re-run with --resume", code: 69)
                } catch {
                    // The vision model failed on this page (a timeout, or it got stuck repeating itself). Don't lose the
                    // page: fall back to Apple's on-device OCR, which is faster and less accurate on handwriting.
                    let why = error as? ModelError
                    log("sheet \(i + 1): the vision model failed (\(why.map { "\($0)" } ?? "\(error)")); using Apple OCR for this page")
                    let ocr = spec.pageIndices.compactMap { spec.doc.page(at: $0).flatMap { renderPage($0, maxSide: 2600) } }
                        .map(ocrText).joined(separator: "\n--- next page ---\n")
                    notes.handwriting = ocr
                    notes.legible = !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                // Apple's OCR reads the PRINTED form the same way every time; remember it to tell fronts from backs later.
                notes.form_text = sheet.ocr ?? spec.pageIndices.compactMap { spec.doc.page(at: $0).flatMap { renderPage($0, maxSide: 1800) } }
                    .map(ocrText).joined(separator: "\n--- next page ---\n")
                records.append((thisClass, PageRecord(source: spec.source, notes: notes)))
                save(complete: i == specs.count - 1)
                let perSheet = Date().timeIntervalSince(started) / Double(i + 1 - done)
                log("read sheet \(i + 1) of \(specs.count) (\(spec.source)) in \(Int(Date().timeIntervalSince(t0)))s; about \(Int(perSheet * Double(specs.count - i - 1) / 60)) min left")
            }
            // Wrong-lesson guard: if the lesson's positions appear on almost no page, it is probably the wrong lesson.
            if let l = lesson, !l.positions.isEmpty, records.count >= 3 {
                let keys = l.positions.map { String($0.lowercased().filter(\.isLetter)) }
                let withPosition = records.filter { r in
                    let t = String(r.record.notes.handwriting.lowercased().filter(\.isLetter))
                    return keys.contains { t.contains($0) }
                }.count
                if Double(withPosition) < 0.2 * Double(records.count) {
                    log("WARNING: the lesson's positions (\(l.positions.joined(separator: " | "))) appear on only \(withPosition) of \(records.count) pages. This looks like the WRONG LESSON for these sheets, so I am ignoring it (no positions, no goal ratings). Check --lesson.")
                    lesson = nil
                }
            }
            log("analyzing \(records.count) page(s) from their transcripts with \(settings.model)")
            await analyzeAll(&records, brief: lesson, topic: settings.topic, settings: settings)
            save(complete: true)
            log("saved detail data to \(path)\(settings.stripNames ? "" : " (contains names; keep private)")")
            if settings.readOnly { print("Data:    \(path)"); return }
        }

        // 3. Who is who. Only pages with writing count. Identical written names within a class are the
        //    same student. A page with no name that follows a named page (within two pages, same PDF)
        //    is taken to be its back side. Other unnamed pages each count as their own student.
        var studentOf = [Int](repeating: 0, count: records.count)     // record index -> student number
        var studentNames: [String] = [], studentClass: [String] = []  // index = student number - 1
        var byKey: [String: Int] = [:]
        var blankPages = 0, unreadable = 0, attachedBacks = 0
        var lastIndex = -10
        var hasBack = Set<Int>()                                      // students who already have a back side attached
        // Fronts of one handout share nearly all their printed text; a back side prints something different. The
        // printed text comes from Apple's OCR (form_text), which does not vary the way the vision model's does.
        var templates: [String: Set<String>] = [:]
        for cls in Set(records.map(\.cls)) {
            templates[cls] = templateLines(records.filter { $0.cls == cls }.compactMap { $0.record.notes.form_text })
        }
        func looksLikeBack(_ i: Int) -> Bool {
            guard let t = templates[records[i].cls], !t.isEmpty, let text = records[i].record.notes.form_text else { return false }   // no evidence: never merge
            let present = Set(text.split(separator: "\n").map { normLine(String($0)) }).intersection(t)
            return Double(present.count) / Double(t.count) < 0.3        // contains little of the common printed form
        }
        for (i, r) in records.enumerated() {
            let n = r.record.notes
            if !n.legible { unreadable += 1; continue }
            if !n.hasContent { blankPages += 1; continue }
            if n.student_name.isEmpty, settings.attachBacks, i - lastIndex <= 2, studentOf[lastIndex] > 0,
               !hasBack.contains(studentOf[lastIndex]), looksLikeBack(i),          // one back per student, and it must look like one
               records[lastIndex].cls == r.cls, records[lastIndex].record.source == r.record.source {
                studentOf[i] = studentOf[lastIndex]; hasBack.insert(studentOf[i]); attachedBacks += 1; lastIndex = i; continue
            }
            let key = r.cls + "|" + n.student_name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter }
            if !n.student_name.isEmpty, let existing = byKey[key] { studentOf[i] = existing; lastIndex = i; continue }
            studentNames.append(n.student_name); studentClass.append(r.cls)
            studentOf[i] = studentNames.count
            if !n.student_name.isEmpty { byKey[key] = studentOf[i] }
            lastIndex = i
        }
        let studentCount = studentNames.count
        if studentCount == 0 { fail("none of the pages had readable student writing", code: 1) }
        let classes = Array(Set(studentClass)).sorted()
        let multiClass = classes.count > 1

        // Names -> labels (anonymous unless --names), BEFORE anything is summarized.
        let anon = Anonymizer(names: studentNames, showNames: settings.showNames)
        let hide = !settings.showNames
        func clean(_ s: String) -> String { anon.scrub(s, enabled: hide) }

        // 4. Pools of statements (keyed by record number) and per-student facts
        var before: [Int: String] = [:], after: [Int: String] = [:], reflection: [Int: String] = [:]
        var ideas: [Int: String] = [:]
        var discussion: [String] = []
        var changed = 0, same = 0, unclear = 0, bothParts = 0
        var startPos: [Int: String] = [:], endPos: [Int: String] = [:]               // by student number
        var goalRank: [Int: [Int: Int]] = [:], goalExamples: [Int: [String]] = [:]   // goal -> student -> rank
        let positions = lesson?.positions ?? []
        func canonical(_ p: String?) -> String? {
            guard let p, isRealPosition(p) else { return nil }
            return positions.first { $0.lowercased() == p.lowercased() }
        }
        for (i, r) in records.enumerated() where studentOf[i] > 0 {
            let n = r.record.notes, id = i + 1, sNum = studentOf[i]
            if !n.before.isEmpty {
                // Give the theme step the side this student circled, so a theme can't contradict the position counts.
                let side = canonical(n.start_position).map { "[\($0)] " } ?? ""
                before[id] = side + clean(n.before)
            }
            if !n.after.isEmpty { after[id] = clean(n.after) }
            if !isFiller(n.reflection) { reflection[id] = clean(n.reflection) }
            if !n.ideas.isEmpty { ideas[id] = clean(n.ideas.joined(separator: "; ")) }
            if !n.discussion_notes.isEmpty { discussion.append("- " + clean(n.discussion_notes)) }
            if !n.before.isEmpty && !n.after.isEmpty {
                bothParts += 1
                let c = n.change_in_thinking.lowercased()
                if c.contains("no change") || c.contains("did not change") || c.contains("same") { same += 1 }
                else if c.isEmpty || c.contains("unclear") { unclear += 1 }
                else { changed += 1 }
            }
            // A position only counts if the page has writing for that phase.
            if let p = canonical(n.start_position), startPos[sNum] == nil { startPos[sNum] = p }
            if !n.after.isEmpty, let p = canonical(n.end_position) { endPos[sNum] = p }
            for g in n.goal_evidence ?? [] {
                let rank = ["specific": 3, "vague": 2, "none": 1][g.level.lowercased()] ?? 0     // "not asked" = 0
                guard rank > 0 else { continue }
                if rank > (goalRank[g.goal]?[sNum] ?? 0) { goalRank[g.goal, default: [:]][sNum] = rank }
                if rank == 3, !g.evidence.isEmpty, goalExamples[g.goal, default: []].count < 2 {
                    goalExamples[g.goal, default: []].append(clean(shorten(g.evidence, 110)))
                }
            }
        }

        func poolStudents(_ pool: [Int: String]) -> Set<Int> { Set(pool.keys.map { studentOf[$0 - 1] }) }
        func studentTexts(_ pool: [Int: String]) -> [Int: String] {
            var out: [Int: String] = [:]
            for id in pool.keys.sorted() where out[studentOf[id - 1]] == nil { out[studentOf[id - 1]] = pool[id] }
            return out
        }
        func byStudent(_ themes: [Theme]) -> [Theme] {
            themes.map { Theme(label: $0.label, summary: $0.summary,
                               students: Array(Set($0.students.map { studentOf[$0 - 1] })).sorted()) }
                .sorted { $0.students.count > $1.students.count }
        }
        func breakdown(_ t: Theme, _ pool: [Int: String]) -> String {
            guard multiClass else { return "" }
            let all = poolStudents(pool)
            let parts = classes.map { c in
                "\(c) \(t.students.filter { studentClass[$0 - 1] == c }.count)/\(all.filter { studentClass[$0 - 1] == c }.count)"
            }
            return " [" + parts.joined(separator: ", ") + "]"
        }
        func example(_ t: Theme, _ pool: [Int: String]) -> String {
            let texts = studentTexts(pool)
            let topic = Set((t.label + " " + t.summary).lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
            // The quote from the student whose words overlap most with the theme; the first student if none do.
            let scored = t.students.compactMap { s -> (Int, String)? in
                guard let q = texts[s] else { return nil }
                let words = Set(q.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
                return (words.intersection(topic).count, q)
            }
            guard let best = scored.max(by: { $0.0 < $1.0 }) else { return "" }
            return " _e.g. “\(shorten(best.1, 130))”_"
        }
        func describe(_ themes: [Theme], _ pool: [Int: String]) -> String {
            if themes.isEmpty { return "_Nothing readable for this part._\n" }
            let total = poolStudents(pool).count
            return themes.map { t in
                let who = settings.showNames ? t.students.map { anon.labels[$0 - 1] }.joined(separator: ", ")
                    : (t.students.count == 1 ? "Student " : "Students ") + t.students.map(String.init).joined(separator: ", ")
                return "- **\(t.label)** (\(t.students.count) of \(total); \(who))\(breakdown(t, pool)): \(t.summary)\(example(t, pool))"
            }.joined(separator: "\n") + "\n"
        }
        func themeLines(_ t: [Theme], _ pool: [Int: String]) -> String {
            let total = poolStudents(pool).count
            guard !t.isEmpty else { return "(none)" }
            return t.map { th in
                var line = "- \(th.label) (\(shareWords(th.students.count, total)))"
                if multiClass {
                    let all = poolStudents(pool)
                    line += " [" + classes.map { c in "\(c): " + shareWords(th.students.filter { studentClass[$0 - 1] == c }.count,
                                                                         all.filter { studentClass[$0 - 1] == c }.count) }.joined(separator: "; ") + "]"
                }
                return line + ": \(th.summary)"
            }.joined(separator: "\n")
        }

        // 5. Counts computed in code: positions, movement, goal evidence
        func positionTables(_ students: [Int]) -> String {
            guard !positions.isEmpty else { return "" }
            let startKnown = students.filter { startPos[$0] != nil }, endKnown = students.filter { endPos[$0] != nil }
            var t = "| Position | At the start | At the end |\n|---|---|---|\n"
            for p in positions {
                t += "| \(p) | \(startKnown.filter { startPos[$0] == p }.count) of \(startKnown.count) | \(endKnown.filter { endPos[$0] == p }.count) of \(endKnown.count) |\n"
            }
            let both = students.filter { startPos[$0] != nil && endPos[$0] != nil }
            if !both.isEmpty {
                let moved = both.filter { startPos[$0] != endPos[$0] }.count
                t += "\nOf \(both.count) students with both a start and an end position, \(moved) changed position and \(both.count - moved) held.\n\n"
                t += "| Start → End | " + positions.joined(separator: " | ") + " |\n|---|" + positions.map { _ in "---|" }.joined() + "\n"
                for s in positions {
                    t += "| \(s) | " + positions.map { e in "\(both.filter { startPos[$0] == s && endPos[$0] == e }.count)" }.joined(separator: " | ") + " |\n"
                }
            }
            return t
        }
        func goalTallies(_ students: Set<Int>) -> [GoalTally] {
            (lesson?.goals ?? []).map { g in
                var t = GoalTally(goal: g)
                for (s, rank) in goalRank[g.number] ?? [:] where students.contains(s) {
                    if rank == 3 { t.specific += 1 } else if rank == 2 { t.vague += 1 } else { t.none += 1 }
                }
                return t
            }
        }
        let positionMovement: (both: Int, moved: Int)? = {
            guard !positions.isEmpty else { return nil }
            let both = (1...studentCount).filter { startPos[$0] != nil && endPos[$0] != nil }
            return both.isEmpty ? nil : (both.count, both.filter { startPos[$0] != endPos[$0] }.count)
        }()
        let allStudents = Set(1...studentCount)
        let allTallies = goalTallies(allStudents)
        let positionText = positionTables(Array(allStudents))
        /// The same facts in words, for the narrative (no digits to misquote).
        func positionWords() -> String {
            guard !positions.isEmpty else { return "" }
            let sk = (1...studentCount).filter { startPos[$0] != nil }, ek = (1...studentCount).filter { endPos[$0] != nil }
            var lines = positions.map { p in
                "- \(p): at the start \(shareWords(sk.filter { startPos[$0] == p }.count, sk.count)); at the end \(shareWords(ek.filter { endPos[$0] == p }.count, ek.count))"
            }
            if let m = positionMovement { lines.append("- Of students with both a start and an end position, \(shareWords(m.moved, m.both)) changed position.") }
            return lines.joined(separator: "\n")
        }

        // 6. Themes + narrative for each summary model, each written to its own file
        let fileBase = settings.outputPath.map { ($0 as NSString).deletingPathExtension }
            ?? slug(settings.classLabel ?? (readingNow
                ? (settings.files.count > 1 ? "\(fileStem ?? "class")-and-\(settings.files.count - 1)-more" : fileStem ?? "class")
                : (multiClass ? "merged-\(classes.count)-classes" : classes.first ?? "class")))
        var wroteAny = false
        var firstSummary: String?

        for model in settings.summaryModels {
            do {
                log("grouping views and ideas with \(model)")
                func themes(_ kind: String, _ pool: [Int: String]) async throws -> [Theme] {
                    byStudent(try await findThemes(kind: kind, statements: pool, model: model, settings: settings, lesson: lesson))
                }
                let started = try await themes("views at the start of the seminar", before)
                let ended = try await themes("positions at the end of the seminar", after)
                let influences = try await themes("what changed or influenced students' thinking", reflection)
                let shared = try await themes("key ideas the students raised", ideas)

                log("writing the narrative with \(model)")
                let evidence = """
                Pages with writing: \(studentCount) students across \(classes.count) class(es): \(classes.joined(separator: ", ")). \
                \(blankPages) blank or printed-only page(s) and \(unreadable) unreadable page(s) were excluded.
                \(lessonBlock(lesson))
                POSITIONS (in words):
                \(positionWords().isEmpty ? "(the lesson defines no positions)" : positionWords())
                GOALS, as the sheets show them:
                \(allTallies.isEmpty ? "(no goals)" : allTallies.map { "- Goal \($0.goal.number) (\(shorten($0.goal.text, 100))): \($0.status.rawValue); \(shareWords($0.specific, $0.asked)) gave specific evidence" }.joined(separator: "\n"))
                STARTING VIEWS:
                \(themeLines(started, before))
                ENDING POSITIONS:
                \(after.isEmpty ? "NONE: these pages have no ending views. Do not say anything about how views changed." : themeLines(ended, after))
                WHAT INFLUENCED THINKING:
                \(themeLines(influences, reflection))
                IDEAS RAISED:
                \(themeLines(shared, ideas))
                CHANGE IN THINKING: \(positionMovement != nil ? "see the positions above" : (bothParts == 0 ? "not available" : "\(shareWords(changed, bothParts)) of students who recorded both a start and an end view said their thinking changed (self-reported)")).
                STUDENTS' NOTES ON THE DISCUSSION (anonymous):
                \(discussion.isEmpty ? "(none)" : discussion.joined(separator: "\n"))
                """
                let system = """
                You write a short, honest summary of a Socratic seminar for the teacher, using ONLY the evidence given. \
                seminar_overview: one paragraph of at most 120 words on how the seminar went as a whole (engagement, \
                tone, participation, main themes, difficulties), based on the students' own notes about the discussion \
                and the themes. Do not claim facts the evidence lacks (for example that every student participated). \
                thinking_shift: one paragraph of at most 120 words comparing where students started with where they \
                ended up and what influenced them, using the counts and naming ideas that spread. If there is no \
                starting data, say so plainly. \
                lesson_connection: if the lesson's goals are given, one warm, constructive paragraph of at most 130 words: \
                what went well, where there is room to grow, and which goals the sheets cannot show (such as live \
                discussion). Base it ONLY on the goals listed. No grade, no scores. Otherwise an empty string. \
                class_comparison: if there are several classes, one paragraph of at most 120 words on how they \
                differed, using the per-class counts shown in brackets as "class done/total"; otherwise an empty string. \
                Write in aggregate; never cite individual student numbers or names. \
                Do NOT write any digits or percentages: use only the words given ("most", "several", "a few", "about half"). \
                Plain prose. Finish every sentence. If the evidence is thin, say so rather than guessing.
                \(settings.topic.map { "Seminar topic: \($0)" } ?? "")
                """
                var story = try await ask(Narrative.self, model: model, system: system, user: evidence,
                                          schema: narrativeSchema, settings: settings, maxTokens: 1800,
                                          numCtx: 8192, timeout: settings.summaryTimeout)
                story.seminar_overview = withoutNumbers(completeSentences(story.seminar_overview))
                story.thinking_shift = withoutNumbers(completeSentences(story.thinking_shift))
                // These pages may hold only starting views (entry tickets). Then there is NOTHING to say about change,
                // and a model must not be asked to invent it.
                if after.isEmpty && reflection.isEmpty {
                    story.thinking_shift = "These sheets record only where students started (entry tickets); none has an ending view or a reflection, so they cannot show how anyone's thinking shifted. Run this again with the exit tickets to see that."
                }
                story.lesson_connection = allTallies.isEmpty ? "" : withoutNumbers(completeSentences(story.lesson_connection))
                story.class_comparison = multiClass ? completeSentences(story.class_comparison) : ""

                // Assemble the Markdown
                let multi = shared.filter { $0.students.count >= 2 }
                let single = shared.filter { $0.students.count == 1 }
                let hasKey = hide && settings.includeKey && studentNames.contains { !$0.isEmpty }
                var md = "# Socratic seminar summary\n\n"
                md += "_\(studentCount) student(s)"
                md += multiClass ? " in \(classes.count) classes (\(classes.joined(separator: ", ")))" : " (\(classes.first ?? thisClass))"
                md += " from \(records.count) page(s)"
                let leftOut = [blankPages > 0 ? "\(blankPages) blank or printed-only" : nil, unreadable > 0 ? "\(unreadable) unreadable" : nil].compactMap { $0 }
                md += leftOut.isEmpty ? "" : "; " + leftOut.joined(separator: " and ") + " page(s) left out"
                md += attachedBacks > 0 ? "; \(attachedBacks) unnamed page(s) attached to the preceding student as a back side" : ""
                md += ". Names \(settings.showNames ? "shown" : "hidden (Student numbers)"). "
                md += readingNow
                    ? "Read with \(settings.reader == .vision ? "Apple Vision OCR" : settings.model), summarized with \(model); all processing was local."
                    : "Built from saved data, summarized with \(model); all processing was local."
                md += hasKey ? " **This file ends with a private student key; remove it before sharing.**" : ""
                md += "_\n\n"
                md += "## The seminar as a whole\n\n\(story.seminar_overview)\n\n"
                md += "## How thinking shifted\n\n\(story.thinking_shift)\n\n"
                if bothParts > 0, positionMovement == nil {
                    md += "Among the \(bothParts) students who recorded both a start and an end view (self-reported): changed \(changed) · stayed the same \(same) · unclear \(unclear)\n\n"
                }
                if !story.class_comparison.isEmpty { md += "## How the classes compared\n\n\(story.class_comparison)\n\n" }
                md += "## Where students started\n\n" + describe(started, before) + "\n"
                md += "## Where students ended up\n\n" + describe(ended, after) + "\n"
                if !positions.isEmpty {
                    md += "## Where students stood\n\n"
                    md += "The lesson's positions, counted from each student's start and end.\n\n" + positionText + "\n"
                    if multiClass {
                        for c in classes { md += "**\(c)**\n\n" + positionTables((1...studentCount).filter { studentClass[$0 - 1] == c }) + "\n" }
                    }
                }
                md += "## What influenced students' thinking\n\n" + describe(influences, reflection) + "\n"
                md += "## Ideas shared by several students\n\n" + describe(multi, ideas) + "\n"
                if !single.isEmpty { md += "## Ideas raised by one student\n\n" + describe(single, ideas) + "\n" }
                if !allTallies.isEmpty {
                    md += "## Evidence of learning and goals\n\n"
                    md += "Where the sheets show students working toward each goal, and where there is room to grow. This reflects only what students wrote, as read by a model. It doesn't include the live discussion or observer tallies, and a goal that looks weak may simply not have been asked about on the sheet.\n\n"
                    if !story.lesson_connection.isEmpty { md += story.lesson_connection + "\n\n" }
                    md += goalLists(allTallies, examples: goalExamples)
                    md += goalTable(allTallies) + "\n"
                    if multiClass {
                        for c in classes {
                            let cls = Set((1...studentCount).filter { studentClass[$0 - 1] == c })
                            md += "**\(c)**\n\n" + goalTable(goalTallies(cls)) + "\n"
                        }
                    }
                }
                md += "## Caveats\n\n"
                md += "- Everything comes from what students wrote, read by an AI model from handwriting; transcription errors are possible. Spot-check against the originals.\n"
                md += "- Positions and goal ratings come from the model's per-page judgments, and the counts are tallies of those. Theme groupings are the summary model's judgment.\n"
                md += "- Pages are matched to the same student by identical written names within a class (or as an unnamed back side of the page before). One student may be counted twice if their name was written or read differently.\n"
                if hide { md += "- Names written on the sheets were replaced by Student numbers. Names the sheets don't reveal (e.g. a teacher, or a classmate who didn't submit a sheet) are not replaced.\n" }
                if hasKey {
                    md += "\n## Student key (private)\n\n| Student | Name | Class |\n|---|---|---|\n"
                    for (i, name) in studentNames.enumerated() {
                        md += "| Student \(i + 1) | \(name.isEmpty ? "(no name read)" : name) | \(studentClass[i]) |\n"
                    }
                }

                let outPath = settings.outputPath.map {
                    settings.summaryModels.count > 1 ? ($0 as NSString).deletingPathExtension + "_" + slug(model) + ".md" : $0
                } ?? fileBase + "_summary" + (settings.summaryModels.count > 1 ? "_" + slug(model) : "") + ".md"
                try md.write(toFile: (outPath as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
                print("Summary (\(model)): \(outPath)")
                wroteAny = true
                if firstSummary == nil { firstSummary = md }
            } catch ModelError.timedOut(let secs) {
                log("\(model) took longer than \(secs)s on a summarizing step; skipping it. Try a faster --summary-model, or re-run with --from-notes")
            } catch ModelError.notRunning(let why) {
                fail("lost contact with Ollama (\(why))", code: 69)
            } catch {
                log("\(model) failed: \(error); skipping it")
            }
        }
        if let dataPath { print("Data:    \(dataPath)\(settings.stripNames ? "" : "  (contains names; keep private)")") }
        if !wroteAny { fail("no summary could be written; your reading is saved\(dataPath.map { " in \($0)" } ?? ""); re-run with --from-notes", code: 2) }
        if settings.toStdout, let md = firstSummary { print("\n" + md) }
    }
}
