//
//  ChecklistImporter.swift
//  RallyLab
//
//  Reads a clip checklist (.xlsx or .csv) into planned clips. The sheet only
//  has to have a header row with a "Clip ID" column somewhere; the other
//  columns are matched by name when present (Env, Camera position,
//  Lighting, Orientation, Ball type, Notes). An .xlsx is a zip of XML, so it
//  is read with the system unzip and XMLParser rather than a library.
//

import Foundation

enum ChecklistImporter {

    enum ImportError: LocalizedError {
        case unreadable(String)
        case noHeader

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read the checklist: \(why)"
            case .noHeader: return "No header row with a “Clip ID” column was found."
            }
        }
    }

    static func clips(from url: URL) throws -> [PlannedClip] {
        let rows: [[String]]
        switch url.pathExtension.lowercased() {
        case "xlsx": rows = try xlsxRows(url)
        case "csv": rows = try csvRows(url)
        default: throw ImportError.unreadable("use an .xlsx or .csv file.")
        }
        return try plannedClips(rows)
    }

    // MARK: - Rows → clips

    static func plannedClips(_ rows: [[String]]) throws -> [PlannedClip] {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let headerIndex = rows.firstIndex(where: { $0.contains { norm($0) == "clip id" } }) else {
            throw ImportError.noHeader
        }
        let header = rows[headerIndex].map(norm)
        func column(_ names: String...) -> Int? {
            header.firstIndex { h in names.contains { h == $0 || h.hasPrefix($0) } }
        }
        guard let idCol = column("clip id") else { throw ImportError.noHeader }
        let numberCol = column("#")
        let envCol = column("env")
        let cameraCol = column("camera")
        let lightCol = column("lighting")
        let orientCol = column("orientation")
        let ballCol = column("ball")
        let notesCol = column("notes")

        var clips: [PlannedClip] = []
        var seen = Set<String>()
        for row in rows[(headerIndex + 1)...] {
            func cell(_ c: Int?) -> String {
                guard let c, c < row.count else { return "" }
                return row[c].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let id = cell(idCol)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            clips.append(PlannedClip(
                id: id,
                number: Int(Double(cell(numberCol)) ?? Double(clips.count + 1)),
                environment: cell(envCol),
                camera: cell(cameraCol),
                lighting: cell(lightCol),
                orientation: cell(orientCol),
                ball: cell(ballCol),
                notes: cell(notesCol)
            ))
        }
        return clips
    }

    // MARK: - CSV

    static func csvRows(_ url: URL) throws -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ImportError.unreadable("not UTF-8 text.")
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                quoted = true
            } else if ch == "," {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(ch)
            }
            i += 1
        }
        return rows
    }

    // MARK: - XLSX (first worksheet)

    static func xlsxRows(_ url: URL) throws -> [[String]] {
        let shared = (try? unzip(url, entry: "xl/sharedStrings.xml")).map(SharedStringsParser.parse) ?? []
        let sheetEntry = (try? firstSheetEntry(url)) ?? "xl/worksheets/sheet1.xml"
        let sheet = try unzip(url, entry: sheetEntry)
        return SheetParser.parse(sheet, shared: shared)
    }

    private static func unzip(_ archive: URL, entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw ImportError.unreadable("\(entry) is missing — is this really an .xlsx?")
        }
        return data
    }

    /// The first sheet listed in the workbook, resolved through its
    /// relationship file (sheet1.xml isn't guaranteed to be the first tab).
    private static func firstSheetEntry(_ archive: URL) throws -> String {
        let workbook = try unzip(archive, entry: "xl/workbook.xml")
        let rels = try unzip(archive, entry: "xl/_rels/workbook.xml.rels")
        guard let rid = AttributeScanner.first(in: workbook, element: "sheet", attribute: "r:id"),
              let target = AttributeScanner.target(in: rels, id: rid) else {
            throw ImportError.unreadable("no worksheet found.")
        }
        let trimmed = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        return trimmed
    }
}

// MARK: - XML helpers

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [[String]] = []
    private var row: [Int: String] = [:]
    private var cellColumn = 0
    private var cellType = ""
    private var value = ""
    private var capturing = false

    private init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let delegate = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    /// "AB12" → 27 (zero-based column).
    private static func column(of ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars {
            guard ch.value >= 65, ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64)
        }
        return max(0, n - 1)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row": row = [:]
        case "c":
            cellColumn = Self.column(of: attributes["r"] ?? "A")
            cellType = attributes["t"] ?? ""
            value = ""
        case "v", "t": capturing = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": capturing = false
        case "c":
            if cellType == "s", let i = Int(value), i < shared.count {
                row[cellColumn] = shared[i]
            } else {
                row[cellColumn] = value
            }
        case "row":
            guard let last = row.keys.max() else { return }
            rows.append((0...last).map { row[$0] ?? "" })
        default: break
        }
    }
}

/// Just enough attribute lookup for the workbook and its relationships.
private enum AttributeScanner {
    static func first(in data: Data, element: String, attribute: String) -> String? {
        let collector = Collector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.found.first?[attribute]
    }

    static func target(in rels: Data, id: String) -> String? {
        let collector = Collector(element: "Relationship")
        let parser = XMLParser(data: rels)
        parser.delegate = collector
        parser.parse()
        return collector.found.first { $0["Id"] == id }?["Target"]
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let element: String
        var found: [[String: String]] = []
        init(element: String) { self.element = element }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == element || qualifiedName == element { found.append(attributes) }
        }
    }
}
