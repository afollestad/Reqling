import Foundation

/// The smallest replacement that turns one text into another: the span between their common prefix and suffix.
///
/// `CodeTextView.replaceText(with:)` applies outside changes through it, so the undo step covers only what changed
/// and a selection outside that span keeps its place. Lengths are UTF-16, as `NSRange` is.
struct TextEdit: Equatable {
    /// The replaced span, in the old text.
    let range: NSRange
    let replacement: String

    static func minimal(from old: NSString, to new: NSString) -> TextEdit {
        let oldLength = old.length
        let newLength = new.length
        var prefix = 0
        while prefix < min(oldLength, newLength), old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        // A boundary inside a surrogate pair or an emoji sequence would cut the replacement into invalid UTF-16.
        if prefix < oldLength {
            prefix = min(prefix, old.rangeOfComposedCharacterSequence(at: prefix).location)
        }
        if prefix < newLength {
            prefix = min(prefix, new.rangeOfComposedCharacterSequence(at: prefix).location)
        }
        var suffix = 0
        while suffix < min(oldLength, newLength) - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        suffix = min(suffix, alignedSuffix(suffix, in: old), alignedSuffix(suffix, in: new))
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        return TextEdit(range: NSRange(location: prefix, length: oldLength - prefix - suffix), replacement: replacement)
    }

    /// Where `selection` lands after this edit: unchanged before the span, shifted after it, and collapsed to the end
    /// of the replacement when it overlapped the span.
    func mapping(_ selection: NSRange) -> NSRange {
        let replacementLength = (replacement as NSString).length
        if NSMaxRange(selection) <= range.location {
            return selection
        }
        if selection.location >= NSMaxRange(range) {
            return NSRange(location: selection.location + replacementLength - range.length, length: selection.length)
        }
        return NSRange(location: range.location + replacementLength, length: 0)
    }

    /// Shrinks a common suffix whose first unit sits inside a composed character sequence to start after it.
    private static func alignedSuffix(_ suffix: Int, in text: NSString) -> Int {
        let start = text.length - suffix
        guard suffix > 0, start < text.length else {
            return suffix
        }
        let sequence = text.rangeOfComposedCharacterSequence(at: start)
        return sequence.location < start ? text.length - NSMaxRange(sequence) : suffix
    }
}
