import Foundation
internal import ReqlingGraphQLEngine
import Synchronization

/// A problem with a GraphQL document, positioned in UTF-16 offsets.
public struct GraphQLDiagnostic: Hashable, Sendable {
    public enum Severity: Hashable, Sendable {
        case error
        /// Still runs: something deprecated, or an operation name the server would not find.
        case warning
    }

    public let severity: Severity
    public let message: String
    /// What to mark: a name where the problem has one, otherwise the token it points at; never empty, except in an
    /// empty document.
    public let range: NSRange
}

/// Checks queries against one schema, through GraphQLSwift's spec validation: syntax, unknown fields, arguments,
/// types, and enum values, missing required arguments, values of the wrong type, and more, plus use of deprecated
/// elements as warnings. `{{templates}}` are masked first (`GraphQLTemplateMask`), so a query is checked as it reads
/// before its variables resolve.
///
/// Building GraphQLSwift's schema is the costly part, so it happens on the first check and is kept; checks are
/// CPU-bound and run one at a time, so call them off the main actor. A schema GraphQLSwift cannot rebuild still gets
/// syntax checks.
public final class GraphQLDocumentValidator: Sendable {
    /// Syntax checks for a request with no schema.
    public static let syntaxOnly = GraphQLDocumentValidator(typeSystem: nil)

    /// GraphQLSwift's parser recurses; deeper nesting is refused rather than risking the stack.
    static let depthLimit = 64

    private let typeSystem: GraphQLTypeSystem?
    private let state = Mutex<State>(State())

    private struct State {
        var checker: GraphQLDocumentChecker?
        var buildIssue: String?
    }

    public init(typeSystem: GraphQLTypeSystem?) {
        self.typeSystem = typeSystem
    }

    /// Why only syntax is being checked, once the first check has tried to build the schema.
    public var issue: String? {
        state.withLock { $0.buildIssue }
    }

    /// The document's problems, ordered by position. `operationName` is the request's Operation field; with several
    /// operations in the document it must name one of them.
    public func diagnostics(for query: String, operationName: String? = nil) -> [GraphQLDiagnostic] {
        let tokens = GraphQLLexer.tokens(in: query)
        guard !tokens.isEmpty else {
            return []
        }
        if let tooDeep = depthDiagnostic(tokens) {
            return [tooDeep]
        }
        let mask = GraphQLTemplateMask(query, tokens: tokens, typeSystem: typeSystem ?? .empty)
        let problems = state.withLock { state in
            checker(&state).problems(in: mask.text)
        }
        var seen: Set<GraphQLDiagnostic> = []
        let length = query.utf16.count
        var diagnostics = problems.compactMap { problem -> GraphQLDiagnostic? in
            let range = problem.ranges.first ?? Self.tokenRange(at: problem.positions.first ?? 0, in: tokens, length: length)
            guard !mask.covers(range.location, syntaxError: problem.kind == .syntax, tokens: tokens) else {
                return nil
            }
            let diagnostic = GraphQLDiagnostic(
                severity: problem.kind == .deprecated ? .warning : .error,
                message: problem.message,
                range: Self.clamped(range, to: length)
            )
            return seen.insert(diagnostic).inserted ? diagnostic : nil
        }
        diagnostics += operationNameDiagnostics(tokens, operationName: operationName)
        return diagnostics.sorted { $0.range.location < $1.range.location }
    }

    private func checker(_ state: inout State) -> GraphQLDocumentChecker {
        if let checker = state.checker {
            return checker
        }
        guard let typeSystem else {
            state.checker = .syntaxOnly
            return .syntaxOnly
        }
        let checker: GraphQLDocumentChecker
        do {
            checker = try GraphQLDocumentChecker(sdl: typeSystem.sdl(.init(assumesUnknownRepeatable: true)))
        } catch {
            // Defaults a server printed as something other than GraphQL literals are the usual culprit.
            do {
                checker = try GraphQLDocumentChecker(sdl: typeSystem.sdl(.init(assumesUnknownRepeatable: true, dropsDefaults: true)))
            } catch {
                state.buildIssue = "Only syntax is checked: the schema could not be rebuilt for validation (\(error.message))."
                checker = .syntaxOnly
            }
        }
        state.checker = checker
        return checker
    }

    private func depthDiagnostic(_ tokens: [GraphQLToken]) -> GraphQLDiagnostic? {
        var depth = 0
        for token in tokens where token.kind == .punctuator {
            switch token.text {
            case "{", "(", "[":
                depth += 1
                if depth > Self.depthLimit {
                    return GraphQLDiagnostic(
                        severity: .warning,
                        message: "This document nests deeper than \(Self.depthLimit) levels, too deep to check.",
                        range: token.range
                    )
                }
            case "}", ")", "]":
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return nil
    }

    /// A document with several operations runs only the one its request names, so a missing or unknown name means the
    /// server refuses it. A name built from templates is left alone until it resolves.
    private func operationNameDiagnostics(_ tokens: [GraphQLToken], operationName: String?) -> [GraphQLDiagnostic] {
        var parser = GraphQLDocumentParser(typeSystem: typeSystem ?? .empty)
        for token in tokens {
            _ = parser.consume(token)
        }
        let operations = parser.outline.operations
        let name = operationName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let first = operations.first, !name.contains("{{") else {
            return []
        }
        if name.isEmpty {
            guard operations.count > 1 else {
                return []
            }
            return [GraphQLDiagnostic(
                severity: .warning,
                message: "This document has \(operations.count) operations; name the one to run in Operation.",
                range: first.keywordRange
            )]
        }
        guard !operations.contains(where: { $0.name == name }) else {
            return []
        }
        return [GraphQLDiagnostic(severity: .warning, message: "No operation here is named “\(name)”.", range: first.keywordRange)]
    }

    /// The token a position-only problem points at: the one holding or starting at it, else the last one.
    private static func tokenRange(at position: Int, in tokens: [GraphQLToken], length: Int) -> NSRange {
        if let token = tokens.first(where: { $0.range.location <= position && position < $0.end })
            ?? tokens.first(where: { $0.range.location >= position }) {
            return token.range
        }
        return tokens.last?.range ?? NSRange(location: max(0, length - 1), length: min(1, length))
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), max(0, length - 1))
        let end = min(max(location + 1, NSMaxRange(range)), length)
        return NSRange(location: location, length: max(0, end - location))
    }
}

extension GraphQLTypeSystem {
    /// No types: what a document is read against when only its syntax matters.
    static let empty = GraphQLTypeSystem(rootTypes: [:], types: [])
}
