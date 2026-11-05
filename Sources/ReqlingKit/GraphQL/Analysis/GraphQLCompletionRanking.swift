/// How typed text narrows a list of names, for completion and the schema browser's search alike, so both find the
/// same things in the same order.
///
/// A name matches when it starts with the text (exact case first, then any case) or holds its characters in order
/// (`fstNm` finds `firstName`); anything else is dropped. Deprecated entries sink below current ones, and ties keep
/// their given order, which is the schema's.
public enum GraphQLCompletionRanking {
    public static func rank<Element>(
        _ elements: [Element],
        by text: String,
        name: (Element) -> String,
        isDeprecated: (Element) -> Bool
    ) -> [Element] {
        let scored = elements.enumerated().compactMap { index, element -> Scored<Element>? in
            score(name(element), for: text).map { Scored(score: $0, isDeprecated: isDeprecated(element), index: index, element: element) }
        }
        return scored.sorted { lhs, rhs in
            if lhs.isDeprecated != rhs.isDeprecated {
                return !lhs.isDeprecated
            }
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.index < rhs.index
        }.map(\.element)
    }

    private struct Scored<Element> {
        let score: Int
        let isDeprecated: Bool
        let index: Int
        let element: Element
    }

    /// Lower is better; nil drops the name. Empty text matches everything equally.
    static func score(_ name: String, for text: String) -> Int? {
        guard !text.isEmpty else {
            return 0
        }
        if name.hasPrefix(text) {
            return name == text ? 0 : 1
        }
        if name.lowercased().hasPrefix(text.lowercased()) {
            return 2
        }
        var remaining = text.lowercased()[...]
        for character in name.lowercased() where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty {
                return 3
            }
        }
        return nil
    }
}
