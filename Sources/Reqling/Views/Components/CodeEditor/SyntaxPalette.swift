import AppKit
import ReqlingKit
import ReqlingTemplating
import SwiftUI

/// Syntax and variable-token colors. Every color is a dynamic `NSColor` with explicit light and dark values, so
/// text that was colored once follows appearance changes without being re-highlighted.
enum SyntaxPalette {
    static let base = NSColor.labelColor

    static func color(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: keyword
        case .string: string
        case .property: property
        case .comment: comment
        case .number: number
        case .symbol: symbol
        }
    }

    // Light and dark values follow Alveary's `SyntaxHighlighter.Palette`, plus a property color for object keys.
    static let keyword = dynamic(light: RGB(0.64, 0.08, 0.50), dark: RGB(0.64, 0.74, 1.0))
    static let string = dynamic(light: RGB(0.77, 0.10, 0.10), dark: RGB(0.98, 0.72, 0.68))
    static let property = dynamic(light: RGB(0.05, 0.38, 0.55), dark: RGB(0.50, 0.82, 0.95))
    static let comment = dynamic(light: RGB(0.25, 0.45, 0.12), dark: RGB(0.53, 0.57, 0.60))
    static let number = dynamic(light: RGB(0.10, 0.31, 0.60), dark: RGB(0.82, 0.82, 0.88))
    static let symbol = dynamic(light: RGB(0.33, 0.36, 0.42), dark: RGB(0.74, 0.78, 0.86))

    /// Pill fills and text for `{{variable}}` tokens, by resolution state. Resolved ones take `accent`, the view's
    /// `appAccent`.
    static func tokenFill(for state: TemplateTokenState, accent: NSColor) -> NSColor {
        switch state {
        case .resolved: accent.withAlphaComponent(0.18)
        case .unresolved: NSColor.systemRed.withAlphaComponent(0.18)
        case .dynamic: NSColor.secondaryLabelColor.withAlphaComponent(0.16)
        }
    }

    static func tokenText(for state: TemplateTokenState, accent: NSColor) -> NSColor {
        switch state {
        case .resolved: accent
        case .unresolved: NSColor.systemRed
        case .dynamic: NSColor.secondaryLabelColor
        }
    }

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private static func dynamic(light: RGB, dark: RGB) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
}

/// How a `{{variable}}` token reads in the editor.
enum TemplateTokenState: Hashable {
    case resolved
    case unresolved
    case dynamic
}

/// What the editor knows about the variables in scope: which names resolve, what to show on hover, and what to
/// complete after `{{`.
struct TemplateTokenContext: Equatable {
    struct Entry: Equatable {
        /// Already masked for secrets.
        let displayValue: String
        let sourceName: String
        /// No environment holds it yet: a script sets it, and `sourceName` names that script.
        var isSetByScript = false
    }

    var entries: [String: Entry]

    static let empty = TemplateTokenContext(entries: [:])

    init(entries: [String: Entry]) {
        self.entries = entries
    }

    init(scope: VariableScope) {
        entries = scope.entries.mapValues { entry in
            let source: String
            switch entry.source {
            case .environment(_, let name): source = name
            case .override: source = "Override"
            case .iterationData: source = "Data"
            case .script: source = "Script"
            }
            return Entry(
                displayValue: entry.isSecret ? TemplateResolver.mask : entry.value,
                sourceName: entry.isCurrentValue ? "\(source), current value set by a script" : source
            )
        }
    }

    func state(for token: TemplateToken) -> TemplateTokenState {
        switch token.kind {
        case .dynamic:
            DynamicVariables.isKnown(token.name) ? .dynamic : .unresolved
        case .variable:
            entries[token.name] == nil ? .unresolved : .resolved
        }
    }

    func tooltip(for token: TemplateToken) -> String {
        switch token.kind {
        case .dynamic:
            return DynamicVariables.isKnown(token.name) ? "Generated each time the request is sent" : "Unknown built-in variable"
        case .variable:
            guard let entry = entries[token.name] else {
                return "“\(token.name)” is not defined in this environment"
            }
            if entry.isSetByScript {
                return "Set by \(entry.sourceName)"
            }
            return "\(entry.displayValue)\nFrom \(entry.sourceName)"
        }
    }

    /// Variable names, then built-ins, that start with `prefix`.
    func completions(matching prefix: String) -> [String] {
        let names = entries.keys.sorted() + DynamicVariables.names
        guard !prefix.isEmpty else {
            return names
        }
        return names.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
    }
}
