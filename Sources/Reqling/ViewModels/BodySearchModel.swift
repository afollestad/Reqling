import AppKit
import Foundation
import Observation
import ReqlingKit

/// What a body search runs over: the text Pretty and Raw show, or the tree Tree mode shows.
enum BodySearchTarget: Sendable {
    case text(TextDocument)
    case tree(BodyStructure)

    var id: UUID {
        switch self {
        case .text(let document): document.id
        case .tree(let structure): structure.id
        }
    }

    /// Changes as a streaming call's timeline grows under the same `id`.
    var revision: Int {
        if case .tree(let structure) = self {
            return structure.revision
        }
        return 0
    }
}

/// A search's matches: byte ranges in text, or node paths in a tree.
struct BodySearchResult: Equatable {
    var textMatches: [Range<Int>] = []
    var treeMatches: [BodyTreeMatch] = []
    /// The search stopped at its limit; there are more.
    var isTruncated = false

    static let empty = BodySearchResult()

    var count: Int {
        max(textMatches.count, treeMatches.count)
    }
}

/// Searching one body in place: the query, its matches in what is shown, and which one is current.
///
/// The search runs off the main actor from the view's `.task(id:)`, keyed on the query and what is searched, so
/// typing or switching formats cancels a search still running and starts the next.
@MainActor
@Observable
final class BodySearchModel {
    var isPresented = false
    var query = ""
    private(set) var result: BodySearchResult = .empty
    private(set) var currentIndex: Int?
    /// Bumped to move keyboard focus into the search field.
    private(set) var focusRequest = 0
    /// What the last search ran over, so a rerun on a growing call's timeline keeps the current match.
    @ObservationIgnored private var lastSearch: (query: String, targetID: UUID)?

    /// What a search depends on, for the view's `.task(id:)`.
    struct Key: Hashable {
        let query: String
        let isPresented: Bool
        let targetID: UUID?
        let revision: Int
    }

    func key(for target: BodySearchTarget?) -> Key {
        Key(query: query, isPresented: isPresented, targetID: target?.id, revision: target?.revision ?? 0)
    }

    var currentTextMatch: Range<Int>? {
        currentIndex.flatMap { $0 < result.textMatches.count ? result.textMatches[$0] : nil }
    }

    var currentTreeMatch: BodyTreeMatch? {
        currentIndex.flatMap { $0 < result.treeMatches.count ? result.treeMatches[$0] : nil }
    }

    /// "3 of 120", "10,000+" when the search stopped at its limit, or "No matches".
    var status: String {
        guard !query.isEmpty else {
            return ""
        }
        let count = result.count
        guard count > 0 else {
            return "No matches"
        }
        let total = result.isTruncated ? "\(count.formatted())+" : count.formatted()
        return currentIndex.map { "\(($0 + 1).formatted()) of \(total)" } ?? total
    }

    func present() {
        isPresented = true
        focusRequest += 1
    }

    func dismiss() {
        isPresented = false
        result = .empty
        currentIndex = nil
    }

    func next() {
        step(by: 1)
    }

    func previous() {
        step(by: -1)
    }

    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .nextMatch where isPresented:
            next()
        case .previousMatch where isPresented:
            previous()
        case .hideFindInterface:
            dismiss()
        default:
            present()
        }
    }

    /// Searches `target` for the query, replacing the matches unless a newer search cancels this one first.
    func search(in target: BodySearchTarget?) async {
        guard isPresented, let target, !query.isEmpty else {
            result = .empty
            currentIndex = nil
            return
        }
        let query = query
        let work = Task.detached(priority: .userInitiated) {
            try Self.find(query, in: target)
        }
        let found = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let found else {
            return
        }
        // The same query over the same timeline, grown by new messages, keeps its place rather than jumping back.
        let isRerun = lastSearch?.query == query && lastSearch?.targetID == target.id
        lastSearch = (query, target.id)
        result = found
        if found.count == 0 {
            currentIndex = nil
        } else if isRerun, let currentIndex {
            self.currentIndex = min(currentIndex, found.count - 1)
        } else {
            currentIndex = 0
        }
    }

    // A separate function rather than a typed-throws closure in `search`: the closure crashed the compiler's ownership
    // verifier (Swift 6.4).
    nonisolated private static func find(_ query: String, in target: BodySearchTarget) throws(CancellationError) -> BodySearchResult {
        switch target {
        case .text(let document):
            let found = try document.find(query)
            return BodySearchResult(textMatches: found.matches, isTruncated: found.isTruncated)
        case .tree(let structure):
            let found = try structure.find(query)
            return BodySearchResult(treeMatches: found.matches, isTruncated: found.isTruncated)
        }
    }

    private func step(by offset: Int) {
        let count = result.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        currentIndex = ((currentIndex ?? (offset > 0 ? -1 : 0)) + offset + count) % count
    }
}
