import Foundation
import ArgumentParser
import CoreGraphics

extension DetectionMode: ExpressibleByArgument {}
extension Scope: ExpressibleByArgument {}
extension NamePages: ExpressibleByArgument {}
extension NameExtent: ExpressibleByArgument {}
extension FillStyle: ExpressibleByArgument {}

@main
struct RedactNames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redact_names",
        abstract: "Black out student names on scanned work. Runs entirely on this Mac.",
        discussion: """
        <input> can be a folder or a single file.

        Folder: reads every PDF/PNG/JPG/TIFF in it and writes redacted copies, with the same \
        file names, to a sibling folder named <input>_redacted.

        File: writes <name>_redacted.<ext> next to the original.

        Output PDFs are flattened to images, so no text layer survives.
        """)

    @Argument(help: "A folder of scans, or a single scan file.")
    var input: String

    @Flag(help: "Draw red outlines instead of black fill, to check box placement.")
    var preview = false

    @Option(help: "Text file with one student name per line.")
    var roster: String?

    @Option(help: "Roster match threshold, 0-1.")
    var fuzzy: Double = 0.85

    @Option(help: "Vertical padding above the name, in line heights.")
    var pad: Double = 1.5

    @Option(help: "Extra pixels around each box.")
    var margin: Double = 8

    @Option(name: .customLong("fallback-top"),
            help: "If page 1 has no 'Name:' label, black out this top fraction of the page (0-1).")
    var fallbackTop: Double?

    @Option(help: "PDF render resolution.")
    var dpi: Int = 200

    @Option(help: "Where to redact: 'page' (the Name: label plus name-like words anywhere) or 'header' (only the top of each page; the body is never touched).")
    var scope: Scope = .page

    @Option(name: .customLong("header-fraction"),
            help: "With --scope header: the top fraction of each page that counts as the header (0-1).")
    var headerFraction: Double = 0.22

    @Option(name: .customLong("name-pages"),
            help: "Which pages are searched for a Name: label: 'first' or 'all'. --scope header always uses 'all'.")
    var namePages: NamePages = .first

    @Option(name: .customLong("name-extent"),
            help: "How far the name band runs: 'width' (one strip across most of the page, the default), 'stop' (to the next printed label such as Date/Period), or 'edge' (to the page edge).")
    var nameExtent: NameExtent = .width

    @Option(name: .customLong("side-margin"),
            help: "With --name-extent width: the fraction of the page width left clear on each side (0-0.4).")
    var sideMargin: Double = 0.05

    @Option(name: .customLong("name-lines"),
            help: "Also black out this many text lines directly below the Name line (0 = none). Names often wrap.")
    var nameLines: Int = 1

    @Option(help: "How redactions look: black, gray, white, or label (light gray with the word REDACTED). All remove the pixels completely.")
    var fill: FillStyle = .black

    @Flag(name: .customLong("no-infer-name-area"),
          help: "Don't copy the Name area onto pages where the label wasn't found (on by default when most pages had one).")
    var noInferNameArea = false

    @Flag(name: .customLong("no-auto-names"),
          help: "Don't look for name-like words outside the Name: label (on by default).")
    var noAutoNames = false

    @Option(help: "How hard to look for names outside Name: (standard or aggressive).")
    var mode: DetectionMode = .standard

    @Flag(help: "Print each flagged word and why. This shows text from the scan, so use it on practice files.")
    var explain = false

    @Flag(help: "Ask a local Ollama model whether any name is still visible in each output page.")
    var verify = false

    @Option(help: "Ollama vision model used by --verify.")
    var model: String = "qwen3-vl:8b"

    mutating func validate() throws {
        if verify && preview { throw ValidationError("--verify checks real redactions; don't combine it with --preview") }
        guard (0...1).contains(fuzzy) else { throw ValidationError("--fuzzy must be between 0 and 1") }
        if let f = fallbackTop, !(0...1).contains(f) {
            throw ValidationError("--fallback-top must be between 0 and 1")
        }
        guard dpi >= 72 else { throw ValidationError("--dpi must be at least 72") }
        guard (0.05...1).contains(headerFraction) else { throw ValidationError("--header-fraction must be between 0.05 and 1") }
        guard (0...0.4).contains(sideMargin) else { throw ValidationError("--side-margin must be between 0 and 0.4") }
        guard nameLines >= 0 else { throw ValidationError("--name-lines must be 0 or more") }
    }

    mutating func run() async throws {
        let fm = FileManager.default
        let inURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inURL.path, isDirectory: &isDir) else {
            throw ValidationError("\(input) does not exist")
        }
        let parent = inURL.deletingLastPathComponent()

        // Work out which files to process and where each result and the log go.
        let files: [URL]
        let outputFor: (URL) -> URL
        let logURL: URL
        let destination: String
        if isDir.boolValue {
            let outDir = parent.appendingPathComponent(inURL.lastPathComponent + "_redacted", isDirectory: true)
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            files = try fm.contentsOfDirectory(at: inURL, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])
                .filter { PageIO.supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            outputFor = { outDir.appendingPathComponent($0.lastPathComponent) }
            logURL = outDir.appendingPathComponent("review_log.csv")
            destination = outDir.path
        } else {
            guard PageIO.supportedExtensions.contains(inURL.pathExtension.lowercased()) else {
                throw ValidationError("\(inURL.lastPathComponent): unsupported type (use PDF, PNG, JPG or TIFF)")
            }
            let stem = inURL.deletingPathExtension().lastPathComponent
            files = [inURL]
            outputFor = { parent.appendingPathComponent(stem + "_redacted").appendingPathExtension($0.pathExtension) }
            logURL = parent.appendingPathComponent(stem + "_review_log.csv")
            destination = outputFor(inURL).path
        }

        var options = RedactOptions(preview: preview, pad: CGFloat(pad), margin: CGFloat(margin),
                                    fallbackTop: fallbackTop.map { CGFloat($0) }, dpi: dpi, explain: explain)
        options.scope = scope
        options.headerFraction = CGFloat(headerFraction)
        options.namePagesAll = namePages == .all
        options.nameExtent = nameExtent
        options.inferNameArea = !noInferNameArea
        options.sideMargin = CGFloat(sideMargin)
        options.nameLines = nameLines
        if !noAutoNames { options.names = NameDetector(mode: mode) }
        if let roster {
            let names = try RosterMatcher.load(from: URL(fileURLWithPath: (roster as NSString).expandingTildeInPath))
            options.roster = RosterMatcher(names: names, threshold: fuzzy)
            print("Roster: \(names.count) name(s)")
        }
        let verifier = verify ? OllamaVerifier(model: model) : nil
        var verifierWorking = verify          // flips to false if Ollama can't be reached

        print("Redacting \(files.count) file(s) -> \(destination)")
        var log = ReviewLog()

        for file in files {
            let name = file.lastPathComponent
            do {
                let pages = try PageIO.loadPages(from: file, dpi: options.dpi)
                var output: [CGImage] = []
                // Pass 1: look at every page. Pass 2: if most pages had a Name area, copy it onto the rest.
                var results = try pages.enumerated().map { try Redactor.plan(page: $0.offset, image: $0.element, options: options) }
                Redactor.inferNameAreas(&results, options: options)
                for (i, image) in pages.enumerated() {
                    let r = results[i]
                    let redacted = PageIO.draw(boxes: r.boxes, on: image, preview: options.preview, style: fill)
                    output.append(redacted)

                    var status = r.inferredNameArea ? "OK (name area copied from other pages)" : "OK"
                    if let reason = r.checkReason {
                        status = "CHECK: \(reason)"
                            + (r.firstPageMissingLabel && options.fallbackTop != nil ? " (top of page blacked out)" : "")
                    }
                    var note = (r.rosterHits > 0 ? " roster hits: \(r.rosterHits)" : "")
                        + (r.nameHits > 0 ? " name-like words: \(r.nameHits)" : "")

                    if let verifier, verifierWorking {
                        switch await verifier.check(redacted) {
                        case .nameVisible(let answer):
                            status = "CHECK: verify reports a visible name"
                            note += "  verify: \(oneLine(answer))"
                        case .clear:
                            note += "  verify: no name"
                        case .unclear(let answer):
                            status = "CHECK: verify answer unclear"
                            note += "  verify: \(oneLine(answer))"
                        case .unavailable(let why):
                            verifierWorking = false
                            print("  warning: --verify disabled for this run: \(why)")
                        }
                    }
                    for line in r.explanations { print("      \(line)") }
                    log.add(file: name, page: i + 1, status: status)
                    print("  \(name) p\(i + 1): \(r.boxes.count) box(es)\(note)  [\(status)]")
                }
                try PageIO.write(output, to: outputFor(file), dpi: options.dpi)
            } catch {
                log.add(file: name, page: 0, status: "CHECK: error - \(error)")
                print("  \(name): ERROR \(error)")
            }
        }

        try log.write(to: logURL)
        print("\nDone. \(log.rows.count) page(s) processed, \(log.flaggedCount) flagged CHECK.")
        print("Review log: \(logURL.path)")
    }

    /// Collapse a model answer to one short line for the console.
    private func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 120 ? String(flat.prefix(120)) + "..." : flat
    }
}
