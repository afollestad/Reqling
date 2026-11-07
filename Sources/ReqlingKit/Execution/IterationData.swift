import Foundation

/// A folder or project run's data file: one row per iteration, each column a variable that `{{name}}` and
/// `rq.iterationData` read as text.
///
/// - CSV takes a header row, then RFC 4180 rows: quoted values may hold commas, quotes (`""`), and line breaks. LF and
///   CRLF both end a row, a UTF-8 byte order mark is ignored, and blank lines are skipped. A row shorter than the header
///   leaves its last columns out; a longer one is an error, as are an empty or repeated column name.
/// - JSON is an array of objects. Strings stay as they are, numbers and booleans become their JSON text, `null` leaves
///   the column out, and an array or object becomes compact JSON.
///
/// A file over `maximumBytes`, or with more than `maximumRows` rows, is refused: every row is held in memory for the
/// whole run, and an agent's data travels in one MCP request anyway.
public enum IterationData {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumRows = 10_000

    /// Reads and parses the file at `url`, off the main actor.
    public static func read(_ url: URL) async throws(IterationDataError) -> [[String: String]] {
        let result = await Task.detached { () -> Result<[[String: String]], IterationDataError> in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumBytes else {
                    return .failure(IterationDataError("“\(url.lastPathComponent)” is larger than 16 MB."))
                }
                let data = try Data(contentsOf: url)
                return Result { () throws(IterationDataError) in try parse(data, fileExtension: url.pathExtension) }
            } catch {
                return .failure(IterationDataError("“\(url.lastPathComponent)” couldn't be read: \(error.localizedDescription)"))
            }
        }.value
        return try result.get()
    }

    /// Parses CSV unless `fileExtension` is `json`.
    public static func parse(_ data: Data, fileExtension: String) throws(IterationDataError) -> [[String: String]] {
        guard data.count <= maximumBytes else {
            throw IterationDataError("The data is larger than 16 MB.")
        }
        let rows = fileExtension.lowercased() == "json" ? try parseJSON(data) : try parseCSV(data)
        guard !rows.isEmpty else {
            throw IterationDataError("The data has no rows.")
        }
        guard rows.count <= maximumRows else {
            throw IterationDataError("The data has \(rows.count) rows; a run takes at most 10,000.")
        }
        return rows
    }

    private static func parseJSON(_ data: Data) throws(IterationDataError) -> [[String: String]] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw IterationDataError("The JSON couldn't be read: \(error.localizedDescription)")
        }
        guard let items = object as? [Any] else {
            throw IterationDataError("The JSON must be an array of objects, one per iteration.")
        }
        var rows: [[String: String]] = []
        for (index, item) in items.enumerated() {
            guard let fields = item as? [String: Any] else {
                throw IterationDataError("Item \(index + 1) of the JSON array isn't an object.")
            }
            rows.append(fields.compactMapValues(text))
        }
        return rows
    }

    /// A JSON value as `{{name}}` reads it; `nil` for `null`.
    private static func text(_ value: Any) -> String? {
        switch value {
        case is NSNull:
            return nil
        case let string as String:
            return string
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private static func parseCSV(_ data: Data) throws(IterationDataError) -> [[String: String]] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw IterationDataError("The CSV isn't UTF-8 text.")
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let records = try csvRecords(text)
        guard let header = records.first else {
            return []
        }
        let columns = header.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        var seen: Set<String> = []
        for column in columns {
            guard !column.isEmpty else {
                throw IterationDataError("The CSV's header row has an empty column name.")
            }
            guard seen.insert(column).inserted else {
                throw IterationDataError("The CSV's header row names “\(column)” twice.")
            }
        }
        return try records.dropFirst().map { record throws(IterationDataError) in
            guard record.fields.count <= columns.count else {
                throw IterationDataError("Line \(record.line) of the CSV has \(record.fields.count) values, but the header names \(columns.count).")
            }
            return Dictionary(uniqueKeysWithValues: zip(columns, record.fields))
        }
    }

    private struct CSVRecord {
        let line: Int
        let fields: [String]
    }

    /// The CSV's records, blank lines left out, each with the line it starts on.
    private static func csvRecords(_ text: String) throws(IterationDataError) -> [CSVRecord] {
        var scanner = CSVScanner(text)
        return try scanner.records()
    }

    /// Reads a CSV a value at a time, as RFC 4180 lays it out.
    private struct CSVScanner {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private var found: [CSVRecord] = []
        private var fields: [String] = []
        private var field = String.UnicodeScalarView()
        private var line = 1
        private var recordLine = 1

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func records() throws(IterationDataError) -> [CSVRecord] {
            while let scalar = next() {
                switch scalar {
                case "\"" where field.isEmpty:
                    try readQuoted()
                case ",":
                    endField()
                case "\r", "\n":
                    if scalar == "\r", peek() == "\n" {
                        index += 1
                    }
                    endRecord()
                    line += 1
                    recordLine = line
                default:
                    field.append(scalar)
                }
            }
            if !field.isEmpty || !fields.isEmpty {
                endRecord()
            }
            return found
        }

        /// The rest of a quoted value, through its closing quote; `""` inside it is one quote.
        private mutating func readQuoted() throws(IterationDataError) {
            while let scalar = next() {
                if scalar == "\"" {
                    guard peek() == "\"" else {
                        return
                    }
                    index += 1
                } else if scalar == "\n" {
                    line += 1
                }
                field.append(scalar)
            }
            throw IterationDataError("A quoted value on line \(recordLine) of the CSV never closes.")
        }

        private mutating func next() -> Unicode.Scalar? {
            guard index < scalars.count else {
                return nil
            }
            defer { index += 1 }
            return scalars[index]
        }

        private func peek() -> Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private mutating func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
        }

        private mutating func endRecord() {
            endField()
            if fields != [""] {
                found.append(CSVRecord(line: recordLine, fields: fields))
            }
            fields = []
        }
    }
}

/// Why a data file can't drive a run, saying where.
public struct IterationDataError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
