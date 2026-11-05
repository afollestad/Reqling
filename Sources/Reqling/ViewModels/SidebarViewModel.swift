import Foundation
import Observation
import ReqlingKit

/// One project as the sidebar shows it: its items after the text query and filters.
struct SidebarSection: Identifiable {
    let project: LibraryProject
    let items: [RequestNode]
    let requestCount: Int

    var id: ProjectID {
        project.id
    }
}

/// The sidebar's filter text and filters, and the sections they produce. Shaping is memoized on every input it
/// reads, so a re-render costs a comparison rather than a tree walk.
@MainActor
@Observable
final class SidebarViewModel {
    var query = ""
    var filter = RequestFilter.none
    /// Bumped by the Filter Sidebar command; the search field takes focus when it changes.
    private(set) var focusRequest = 0

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var cache: (key: CacheKey, sections: [SidebarSection])?

    private struct CacheKey: Equatable {
        let query: String
        let filter: RequestFilter
        let projects: [LibraryProject]
        /// `RunHistory.revision` while an outcome filter is on; any other time, outcomes cannot change the sections.
        let historyRevision: Int
    }

    init(app: AppModel) {
        self.app = app
    }

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || filter.isActive
    }

    var sections: [SidebarSection] {
        // Read every observable input before consulting the cache, so observation keeps tracking all of them.
        let key = CacheKey(
            query: query,
            filter: filter,
            projects: app.library.projects,
            historyRevision: filter.outcomes.isEmpty ? 0 : app.runner.history.revision
        )
        if let cache, cache.key == key {
            return cache.sections
        }
        let sections = Self.shape(key, runner: app.runner, isFiltering: isFiltering)
        cache = (key, sections)
        return sections
    }

    func clearFilters() {
        query = ""
        filter = .none
    }

    func requestFocus() {
        focusRequest += 1
    }

    private static func shape(_ key: CacheKey, runner: RequestRunner, isFiltering: Bool) -> [SidebarSection] {
        key.projects.compactMap { project in
            guard let document = project.document else {
                // An unavailable project has nothing to match; it shows only when nothing is filtered.
                return isFiltering ? nil : SidebarSection(project: project, items: [], requestCount: 0)
            }
            guard let items = document.filtered(matching: key.query, filter: key.filter, outcome: { runner.outcome(for: $0, in: project.id) }) else {
                return nil
            }
            return SidebarSection(project: project, items: items, requestCount: countRequests(in: items))
        }
    }

    private static func countRequests(in nodes: [RequestNode]) -> Int {
        nodes.reduce(0) { count, node in
            switch node {
            case .request: count + 1
            case .folder(let folder): count + countRequests(in: folder.children)
            }
        }
    }
}
