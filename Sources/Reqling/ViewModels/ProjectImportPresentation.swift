import Foundation
import ReqlingKit

/// What an import's summary says: what came over, what needs changes grouped by where it is, and what was left
/// out, worded for the import sheet and tested as text, since prose reflows across macOS versions.
struct ProjectImportPresentation: Equatable {
    /// One folder's, request's, environment's, or the project's notes.
    struct Group: Equatable, Identifiable {
        let title: String
        let lines: [String]

        var id: String {
            title
        }
    }

    let title: String
    let summary: String
    let credentials: String?
    let environments: [String]
    let groups: [Group]
    let notImported: String?
    let trust: String?
    let globalProblem: String?

    init(name: String, plan: ProjectImport, result: ProjectLifecycle.ProjectImportResult) {
        title = "Imported “\(name)”"
        let counts = plan.counts
        var parts = [Self.count(counts.requests, "request")]
        if counts.folders > 0 {
            parts[0] += " in \(Self.count(counts.folders, "folder"))"
        }
        if counts.environments > 0 {
            parts.append(Self.count(counts.environments, "environment"))
        }
        summary = Self.listed(parts) + "."
        credentials = counts.credentials.isEmpty ? nil
            : "Literal passwords, tokens, and API keys are secret variables in Default now, kept in your Keychain: "
                + Self.listed(counts.credentials) + "."
        environments = (plan.environmentChanges + [result.globalChange].compactMap(\.self)).compactMap(Self.line)
        groups = Self.groups(plan.notes)
        let omitted = ImportOmission.allCases.compactMap { kind in
            counts.omitted[kind].map { Self.count($0, Self.noun(kind)) }
        }
        notImported = omitted.isEmpty ? nil : "Not imported: \(Self.listed(omitted)), which Reqling has nowhere to keep."
        trust = plan.hasScripts ? "Its scripts run once you trust them: the first request you send with scripts asks." : nil
        globalProblem = result.globalProblem.map { "The globals couldn't be added to the Global environment: \($0)" }
    }

    /// What an import did to one environment: `Staging: new, with 3 variables.`, or `Default: 2 updated, 1 added.`; `nil`
    /// when it changed nothing.
    static func line(_ change: ImportEnvironmentChange) -> String? {
        if change.isNew {
            return "\(change.environment): new, with \(count(change.added.count, "variable"))."
        }
        var parts: [String] = []
        if !change.updated.isEmpty {
            parts.append("\(change.updated.count) updated")
        }
        if !change.added.isEmpty {
            parts.append("\(change.added.count) added")
        }
        return parts.isEmpty ? nil : "\(change.environment): \(parts.joined(separator: ", "))."
    }

    /// The project's notes first, then each folder's and request's in the order the tree has them, then each
    /// environment's.
    private static func groups(_ notes: [ImportNote]) -> [Group] {
        var order: [ImportNote.Owner] = []
        var lines: [ImportNote.Owner: [String]] = [:]
        for note in notes {
            if lines[note.owner] == nil {
                order.append(note.owner)
            }
            lines[note.owner, default: []].append(line(note))
        }
        let sorted = order.filter { $0 == .project } + order.filter(\.isNode) + order.filter(\.isEnvironment)
        return sorted.map { Group(title: title(of: $0), lines: lines[$0] ?? []) }
    }

    private static func line(_ note: ImportNote) -> String {
        if case .script(let phase, let line?) = note.topic {
            return "\(phase.title) script, line \(line): \(note.message)"
        }
        return note.message
    }

    private static func title(of owner: ImportNote.Owner) -> String {
        switch owner {
        case .project: "Project"
        case .node(let path): path.joined(separator: " ▸ ")
        case .environment(let name): "\(name) environment"
        }
    }

    private static func noun(_ kind: ImportOmission) -> String {
        switch kind {
        case .descriptions: "description"
        case .savedResponses: "saved response"
        case .responses: "response definition"
        case .callbacks: "callback"
        case .links: "link"
        case .webhooks: "webhook"
        }
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// `a`, `a and b`, or `a, b, and c`.
    private static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0, 1: items.joined()
        case 2: items.joined(separator: " and ")
        default: items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}

private extension ImportNote.Owner {
    var isNode: Bool {
        if case .node = self {
            return true
        }
        return false
    }

    var isEnvironment: Bool {
        if case .environment = self {
            return true
        }
        return false
    }
}
