import Foundation

/// review_log.csv: one row per page, so a human knows which pages to eyeball.
struct ReviewLog {
    struct Row { let file: String; let page: Int; let status: String }
    private(set) var rows: [Row] = []

    mutating func add(file: String, page: Int, status: String) {
        rows.append(Row(file: file, page: page, status: status))
    }

    /// Pages whose status starts with "CHECK".
    var flaggedCount: Int { rows.filter { $0.status.hasPrefix("CHECK") }.count }

    func write(to url: URL) throws {
        var csv = "file,page,status\n"
        for r in rows { csv += "\(quote(r.file)),\(r.page),\(quote(r.status))\n" }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Wrap in quotes if the text contains a comma or quote (standard CSV rules).
    private func quote(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : s
    }
}
