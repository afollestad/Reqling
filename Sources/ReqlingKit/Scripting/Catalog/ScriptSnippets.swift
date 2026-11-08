import Foundation
import ReqlingScriptProtocol

/// Code the Scripts editor's snippet menu inserts, so a script needn't start from the API reference.
public struct ScriptSnippet: Sendable, Hashable, Identifiable {
    public enum Group: Sendable, Hashable, CaseIterable {
        case variables
        case request
        case tests

        public var title: String {
            switch self {
            case .variables: "Variables"
            case .request: "Request"
            case .tests: "Tests"
            }
        }
    }

    /// The same for each phase's and protocol's version of a snippet, such as `testStatus`.
    public let id: String
    public let title: String
    public let group: Group
    public let code: String
    /// The part to type over once inserted, such as a variable's name, in UTF-16 units of `code`.
    public let placeholder: NSRange?

    /// `marked` writes the placeholder, if any, as Xcode does: `rq.environment.set("<#name#>", "value")`.
    init(id: String, title: String, group: Group, marked: String) {
        self.id = id
        self.title = title
        self.group = group
        guard let open = marked.range(of: Self.placeholderOpen),
              let close = marked.range(of: Self.placeholderClose, range: open.upperBound..<marked.endIndex) else {
            code = marked
            placeholder = nil
            return
        }
        let before = marked[..<open.lowerBound]
        let inner = marked[open.upperBound..<close.lowerBound]
        code = String(before + inner + marked[close.upperBound...])
        placeholder = NSRange(location: before.utf16.count, length: inner.utf16.count)
    }

    static let placeholderOpen = "<#"
    static let placeholderClose = "#>"
}

/// What the snippet menu offers for one phase and owner.
public struct ScriptSnippetMenu: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let group: ScriptSnippet.Group
        public let snippets: [ScriptSnippet]

        public var id: ScriptSnippet.Group {
            group
        }
    }

    /// One protocol's snippets in a folder's or the project's script, each run only for that protocol's requests.
    public struct ProtocolSection: Sendable, Equatable, Identifiable {
        public let kind: RequestKind.Name
        public let snippets: [ScriptSnippet]

        public var id: RequestKind.Name {
            kind
        }
    }

    /// What works for every request the script runs for, by group, leaving out empty groups.
    public let sections: [Section]
    /// Only for a folder's or the project's script: what differs by protocol, under each protocol it fits.
    public let byProtocol: [ProtocolSection]
}

/// The snippets for each phase and request kind, picked the way completion picks the API: only what works where the
/// script runs. `ScriptSnippetsTests` checks each against `ScriptAnalyzer` and `ScriptRunnerTests+Snippets` runs each
/// through the helper, so renaming an API member a snippet uses fails there.
public enum ScriptSnippets {
    /// `kind` is the request's; `nil` for a folder's or the project's script, which runs for every kind. There, a
    /// snippet with a version for every kind is listed as usual, and one whose code differs by kind is listed under
    /// each kind it has, inside `if (rq.info.protocol === "…")`: `RequestKind.Name`'s raw values are the names
    /// `rq.info.protocol` gives.
    public static func menu(for phase: ScriptPhase, kind: RequestKind.Name?) -> ScriptSnippetMenu {
        menus[MenuKey(phase: phase, kind: kind)] ?? build(phase: phase, kind: kind)
    }

    private struct MenuKey: Hashable {
        let phase: ScriptPhase
        let kind: RequestKind.Name?
    }

    /// Built once: the menu reads them on every render of the Scripts pane.
    private static let menus: [MenuKey: ScriptSnippetMenu] = {
        let kinds: [RequestKind.Name?] = RequestKind.Name.allCases + [nil]
        let keys = ScriptPhase.allCases.flatMap { phase in kinds.map { MenuKey(phase: phase, kind: $0) } }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, build(phase: $0.phase, kind: $0.kind)) })
    }()

    private static func build(phase: ScriptPhase, kind: RequestKind.Name?) -> ScriptSnippetMenu {
        let common = entries.compactMap { entry in
            entry.variant(for: phase, kind: kind).map { entry.snippet($0.title, $0.code) }
        }
        let byProtocol: [ScriptSnippetMenu.ProtocolSection] = kind != nil ? [] : RequestKind.Name.allCases.compactMap { guardKind in
            let snippets = entries.compactMap { entry -> ScriptSnippet? in
                guard entry.variant(for: phase, kind: nil) == nil, let variant = entry.variant(for: phase, kind: guardKind) else {
                    return nil
                }
                return entry.snippet(variant.title, guarded(variant.code, to: guardKind))
            }
            return snippets.isEmpty ? nil : ScriptSnippetMenu.ProtocolSection(kind: guardKind, snippets: snippets)
        }
        let sections = ScriptSnippet.Group.allCases.compactMap { group in
            let snippets = common.filter { $0.group == group }
            return snippets.isEmpty ? nil : ScriptSnippetMenu.Section(group: group, snippets: snippets)
        }
        return ScriptSnippetMenu(sections: sections, byProtocol: byProtocol)
    }

    private static func guarded(_ code: String, to kind: RequestKind.Name) -> String {
        let body = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : CodeIndent.indentUnit + $0 }
            .joined(separator: "\n")
        return "if (rq.info.protocol === \"\(kind.rawValue)\") {\n\(body)\n}"
    }
}

extension ScriptSnippets {
    /// One snippet, in a version per phase and kind.
    struct Entry {
        let id: String
        let group: ScriptSnippet.Group
        let variants: [Variant]

        init(_ id: String, _ group: ScriptSnippet.Group, _ variants: [Variant]) {
            self.id = id
            self.group = group
            self.variants = variants
        }

        /// The version for `kind` in `phase`: one written for that kind, failing that one for every kind. For `nil`,
        /// only one for every kind.
        func variant(for phase: ScriptPhase, kind: RequestKind.Name?) -> Variant? {
            let here = variants.filter { $0.phases.contains(phase) }
            if let kind, let own = here.first(where: { $0.kinds?.contains(kind) == true }) {
                return own
            }
            return here.first { $0.kinds == nil }
        }

        func snippet(_ title: String, _ marked: String) -> ScriptSnippet {
            ScriptSnippet(id: id, title: title, group: group, marked: marked)
        }
    }

    struct Variant {
        let title: String
        let phases: Set<ScriptPhase>
        /// `nil` for every kind.
        let kinds: Set<RequestKind.Name>?
        /// With the placeholder marked: `<#name#>`.
        let code: String

        init(_ title: String, _ phases: Set<ScriptPhase>, _ kinds: Set<RequestKind.Name>?, _ code: String) {
            self.title = title
            self.phases = phases
            self.kinds = kinds
            self.code = code
        }
    }
}
