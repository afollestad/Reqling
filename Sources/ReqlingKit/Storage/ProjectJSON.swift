import Foundation

/// The one JSON style every file Reqling writes uses: pretty-printed with sorted keys and a final newline, so files
/// diff cleanly in git and a re-save of unchanged content produces identical bytes.
public enum ProjectJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Builds filesystem-safe, stable file names from item names: `Get user` becomes `get-user`.
enum Slug {
    static func make(_ name: String, fallback: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var lastWasSeparator = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !slug.isEmpty, !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        let trimmed = String(slug.prefix(80))
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Whether `candidate` is `base` or `base-<n>`, so an item keeps its existing file name across unrelated edits.
    static func isVariant(_ candidate: String, of base: String) -> Bool {
        guard candidate.hasPrefix(base) else {
            return false
        }
        let rest = candidate.dropFirst(base.count)
        if rest.isEmpty {
            return true
        }
        return rest.first == "-" && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber)
    }

    /// `base`, or the first `base-<n>` (n ≥ 2) not in `used`.
    static func unique(_ base: String, avoiding used: Set<String>) -> String {
        if !used.contains(base) {
            return base
        }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}

/// Moves deleted project files to the Trash, so every deletion Reqling makes can be undone in Finder.
///
/// Tests inject a temporary-directory implementation; the system one would fill the developer's real Trash.
public protocol FileTrashing: Sendable {
    func trash(_ url: URL) throws
}

public struct SystemTrash: FileTrashing {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Moves "trashed" items into a directory instead of the Trash; for tests.
public struct DirectoryTrash: FileTrashing {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
    }
}
