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
    /// Shows only the requests that failed in the current or last folder or project run; off once its report goes.
    var showsLastRunFailures = false
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
        /// The last run's failed requests while that filter is on.
        let lastRunFailures: Set<RequestNodeID>?
    }

    init(app: AppModel) {
        self.app = app
    }

    /// Whether a folder or project run has a report up, which the "Failed in Last Run" filter needs.
    var hasLastRun: Bool {
        app.batches.hasReport
    }

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || filter.isActive || showsLastRunFailures
    }

    var sections: [SidebarSection] {
        // Read every observable input before consulting the cache, so observation keeps tracking all of them.
        let key = CacheKey(
            query: query,
            filter: filter,
            projects: app.library.projects,
            historyRevision: filter.outcomes.isEmpty ? 0 : app.runner.history.revision,
            lastRunFailures: showsLastRunFailures ? app.batches.failedRequests : nil
        )
        if let cache, cache.key == key {
            return cache.sections
        }
        let sections = Self.shape(key, runner: app.runner, isFiltering: isFiltering)
        cache = (key, sections)
        return sections
    }

    /// Whether the query and filters keep `item` in the sidebar. Its row shows only with its folders expanded too, as
    /// every folder is while filtering, and scrolled to.
    func shows(_ item: SidebarItem) -> Bool {
        guard let section = sections.first(where: { $0.id == item.projectID }) else {
            return false
        }
        return item.nodeID.map { Self.contains($0, in: section.items) } ?? true
    }

    func clearFilters() {
        query = ""
        filter = .none
        showsLastRunFailures = false
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
            guard var items = document.filtered(matching: key.query, filter: key.filter, outcome: { runner.outcome(for: $0, in: project.id) }) else {
                return nil
            }
            if let failures = key.lastRunFailures {
                items = keeping(failures, in: items)
                guard !items.isEmpty else {
                    return nil
                }
            }
            return SidebarSection(project: project, items: items, requestCount: countRequests(in: items))
        }
    }

    /// `nodes` with only the requests in `ids`, and the folders that still hold one.
    private static func keeping(_ ids: Set<RequestNodeID>, in nodes: [RequestNode]) -> [RequestNode] {
        nodes.compactMap { node in
            switch node {
            case .request(let request):
                return ids.contains(request.id) ? node : nil
            case .folder(var folder):
                folder.children = keeping(ids, in: folder.children)
                return folder.children.isEmpty ? nil : .folder(folder)
            }
        }
    }

    private static func contains(_ id: RequestNodeID, in nodes: [RequestNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .request(let request): request.id == id
            case .folder(let folder): folder.id == id || contains(id, in: folder.children)
            }
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
