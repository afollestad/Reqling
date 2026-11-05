import Foundation

/// How one line of a `DiffDocument` reads: kept, added, removed, or standing in for unchanged lines left out.
public struct DiffLineStyle: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context
        case added
        case removed
        /// One row standing for this many unchanged lines.
        case omitted(Int)
    }

    public let kind: Kind
    /// 1-based, in the old text; `nil` for an added or omitted line.
    public let oldNumber: Int?
    /// 1-based, in the new text; `nil` for a removed or omitted line.
    public let newNumber: Int?
}

/// A unified diff of two texts, ready for the code viewer: the lines in order, with no `+` or `-` markers, so copying
/// and searching see the real text, and each line's style beside it.
///
/// Unchanged lines more than `contextRadius` away from a change collapse into one omitted row once there are at least
/// `collapseMinimum` of them; shorter stretches stay, since a summary row would hide about as much as it saves.
public struct DiffDocument: Sendable {
    public static let contextRadius = 3
    public static let collapseMinimum = 8

    public let text: TextDocument
    /// One per line of `text`, except when both texts are empty: then none, though an empty `TextDocument` counts one
    /// line. Such a diff has no changes, which views show as such rather than drawing it.
    public let lines: [DiffLineStyle]
    public let addedCount: Int
    public let removedCount: Int

    public var hasChanges: Bool {
        addedCount + removedCount > 0
    }

    /// Throws once the current task is cancelled.
    public static func make(
        old: String,
        new: String,
        language: SyntaxLanguage,
        maxEditDistance: Int = LineDiff.defaultMaxEditDistance
    ) throws(CancellationError) -> DiffDocument {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        // By bytes: `Substring` compares by canonical equivalence, so lines differing only in Unicode normalization
        // would read as unchanged.
        let edits = try LineDiff.edits(
            from: oldLines.map { Array($0.utf8) },
            to: newLines.map { Array($0.utf8) },
            maxEditDistance: maxEditDistance
        )
        let shown = nearChanges(edits)
        var texts: [Substring] = []
        var styles: [DiffLineStyle] = []
        var added = 0
        var removed = 0
        var index = 0
        while index < edits.count {
            switch edits[index] {
            case .added(let new):
                texts.append(newLines[new])
                styles.append(DiffLineStyle(kind: .added, oldNumber: nil, newNumber: new + 1))
                added += 1
                index += 1
            case .removed(let old):
                texts.append(oldLines[old])
                styles.append(DiffLineStyle(kind: .removed, oldNumber: old + 1, newNumber: nil))
                removed += 1
                index += 1
            case .equal:
                var end = index
                while end < edits.count, case .equal = edits[end], !shown[end] {
                    end += 1
                }
                if end - index >= collapseMinimum {
                    texts.append(omittedText(end - index))
                    styles.append(DiffLineStyle(kind: .omitted(end - index), oldNumber: nil, newNumber: nil))
                    index = end
                } else if case .equal(let old, let new) = edits[index] {
                    texts.append(newLines[new])
                    styles.append(DiffLineStyle(kind: .context, oldNumber: old + 1, newNumber: new + 1))
                    index += 1
                }
            }
        }
        let document = TextDocument(text: texts.joined(separator: "\n"), language: language)
        return DiffDocument(text: document, lines: styles, addedCount: added, removedCount: removed)
    }

    /// Per edit, whether it lies within `contextRadius` of a change, so it shows even inside a long unchanged stretch.
    private static func nearChanges(_ edits: [LineDiff.Edit]) -> [Bool] {
        var shown = Array(repeating: false, count: edits.count)
        for (index, edit) in edits.enumerated() {
            if case .equal = edit {
                continue
            }
            let lower = max(0, index - contextRadius)
            let upper = min(edits.count - 1, index + contextRadius)
            for neighbor in lower...upper {
                shown[neighbor] = true
            }
        }
        return shown
    }

    /// Lines split at each `\n` byte, as `TextDocument` counts them, without a `\r` ending them. Bytes, not
    /// `Character`s: Swift reads `\r\n` as one character, which splitting at `"\n"` never finds. A final line break
    /// starts no further line, and empty text has none, so an empty body compares as nothing, not one blank line.
    static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else {
            return []
        }
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            Substring(line.last == 0x0D ? line.dropLast() : line)
        }
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func omittedText(_ count: Int) -> Substring {
        count == 1 ? "1 unchanged line" : "\(count) unchanged lines"
    }
}
