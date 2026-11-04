import AppKit
import Foundation
import Observation
import ReqlingKit

/// Searching one body in place: the query, its matches in the document shown, and which one is current.
///
/// The search runs off the main actor from the view's `.task(id:)`, keyed on the query and the document, so typing
/// or switching formats cancels a search still running and starts the next.
@MainActor
@Observable
final class BodySearchModel {
    var isPresented = false
    var query = ""
    private(set) var result: TextDocument.SearchResult = .empty
    private(set) var currentIndex: Int?
    /// Bumped to move keyboard focus into the search field.
    private(set) var focusRequest = 0

    /// What a search depends on, for the view's `.task(id:)`.
    struct Key: Hashable {
        let query: String
        let isPresented: Bool
        let documentID: UUID?
    }

    func key(for document: TextDocument?) -> Key {
        Key(query: query, isPresented: isPresented, documentID: document?.id)
    }

    var currentMatch: Range<Int>? {
        currentIndex.map { result.matches[$0] }
    }

    /// "3 of 120", "10,000+" when the search stopped at its limit, or "No matches".
    var status: String {
        guard !query.isEmpty else {
            return ""
        }
        let count = result.matches.count
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
        result = TextDocument.SearchResult.empty
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

    /// Searches `document` for the query, replacing the matches unless a newer search cancels this one first.
    func search(in document: TextDocument?) async {
        guard isPresented, let document, !query.isEmpty else {
            result = TextDocument.SearchResult.empty
            currentIndex = nil
            return
        }
        let query = query
        let work = Task.detached(priority: .userInitiated) {
            try document.find(query)
        }
        let found = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let found else {
            return
        }
        result = found
        currentIndex = found.matches.isEmpty ? nil : 0
    }

    private func step(by offset: Int) {
        let count = result.matches.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        currentIndex = ((currentIndex ?? (offset > 0 ? -1 : 0)) + offset + count) % count
    }
}
