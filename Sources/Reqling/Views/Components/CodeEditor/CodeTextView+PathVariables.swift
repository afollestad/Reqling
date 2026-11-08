import AppKit
import ReqlingScriptProtocol

/// A URL bar's `:name` path variables, found by `RequestPathVariables` as the request builder finds them: colored as a
/// resolved `{{variable}}` is when the row has a value and as an unresolved one when it doesn't, with no pill, since
/// their values live in the request's Params tab rather than an environment.
extension CodeTextView {
    func colorPathVariables(in layoutManager: NSTextLayoutManager) {
        guard let values = pathVariables else {
            pathVariableSegments = []
            return
        }
        pathVariableSegments = RequestPathVariables.segments(in: string)
        for segment in pathVariableSegments {
            guard let range = textRange(for: segment.utf16Range) else {
                continue
            }
            let hasValue = values[segment.name]?.isEmpty == false
            let color = SyntaxPalette.tokenText(for: hasValue ? .resolved : .unresolved, accent: accentColor)
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
        }
    }

    /// What hovering a `:name` segment explains; `nil` away from one.
    func pathVariableToolTip(at point: NSPoint) -> String? {
        let segment = pathVariableSegments.first { segment in
            segmentRects(for: segment.utf16Range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
        guard let segment else {
            return nil
        }
        let value = pathVariables?[segment.name] ?? ""
        return value.isEmpty
            ? "Path variable :\(segment.name) has no value. Set it under Params."
            : "Path variable :\(segment.name) = \(value)"
    }
}
