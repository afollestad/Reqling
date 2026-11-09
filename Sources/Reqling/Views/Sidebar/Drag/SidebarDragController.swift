import AppKit
import Observation
import ReqlingKit
import SwiftUI

/// The sidebar's drag, from a row's gesture passing its threshold to the drop, as Alveary's sidebar drags: rows stay
/// put and the dragged ones fade, a line or border shows where a drop lands, and nothing changes until the mouse comes
/// up. Escape cancels, a closed folder or project opens if the pointer rests on it, and the list scrolls near its
/// edges (`SidebarDragMonitorView`).
///
/// A row's gesture only starts the drag; from there the event monitor at the list's root drives it, since the row can
/// scroll out of the list mid-drag and take its gesture with it. Observed state is only what draws: `state`, which every
/// row reads and which changes as a drag starts and ends, and the candidate and visible frame the overlay reads. Row
/// frames change on every layout pass, so they stay unobserved.
@MainActor
@Observable
final class SidebarDragController {
    enum UpdateReason {
        case pointer
        /// Rows moved or the list scrolled under a still pointer. A `List` can publish a partial set of row frames
        /// before the full one, so a change of target from geometry waits `geometryGrace` before showing.
        case geometry
    }

    /// How long the pointer rests on a closed folder or project before it opens.
    static let springLoadDelay: Duration = .milliseconds(500)
    static let geometryGrace: Duration = .milliseconds(50)

    private(set) var state = SidebarDragState.idle
    private(set) var candidate: SidebarDropCandidate?
    /// The part of the list not under the filter bar or footer, in the window's coordinates (`SidebarDragGeometry`).
    private(set) var visibleFrame: CGRect?
    /// Where the list's top-left corner sits in the window, which the monitor's points and the overlay's drawing start
    /// from. Changes only as the list's layout does.
    private(set) var listOrigin = CGPoint.zero

    @ObservationIgnored let model: AppModel
    @ObservationIgnored let system: SidebarDragSystem
    @ObservationIgnored let listHost = SidebarListHost()
    @ObservationIgnored var reducesMotion = false
    @ObservationIgnored private var frames: [SidebarItem: CGRect] = [:]
    /// Where the monitor saw the pointer before the row's gesture started the drag, which it does on the same event.
    @ObservationIgnored private var pendingMonitorLocation: CGPoint?
    @ObservationIgnored private var geometryMissToken: UUID?
    @ObservationIgnored private var springLoad: (target: SidebarItem, task: Task<Void, Never>)?

    /// `initialDrag` starts a drag at a pointer for a snapshot, which can't move a mouse.
    init(model: AppModel, system: SidebarDragSystem, initialDrag: (source: SidebarItem, pointer: CGPoint)? = nil) {
        self.model = model
        self.system = system
        if let initialDrag, let layout = layout(for: initialDrag.source) {
            state = .active(SidebarDragSession(source: initialDrag.source, sourceNodes: layout.sourceNodes, location: initialDrag.pointer))
        }
    }

    var isIdle: Bool {
        state == .idle
    }

    var animation: Animation? {
        reducesMotion ? nil : .easeInOut(duration: 0.16)
    }

    /// Whether `item`'s row fades: the dragged item, or inside it.
    func isDragged(_ item: SidebarItem) -> Bool {
        state.session?.isDragged(item) ?? false
    }

    /// Whether `item`'s gesture may start or continue a drag; only the dragged row's may while one is under way.
    func isSourceEnabled(_ item: SidebarItem) -> Bool {
        switch state {
        case .idle: true
        case .active(let session): session.source == item
        case .cancelledUntilMouseUp: false
        }
    }

    /// A row's click: selects it, and gives the list's table the keyboard, as the table's own click did. Rows take the
    /// click themselves (`sidebarRowClick`), and Control-click is the context menu's.
    func click(_ item: SidebarItem) {
        guard isIdle, !NSEvent.modifierFlags.contains(.control) else {
            return
        }
        model.selection = item
        listHost.focusTable()
    }

    /// The rows for a drag of `source`, or `nil` when it can't be dragged: while the sidebar is filtered, whose shown
    /// order isn't the saved one, or for an item that is gone or can't leave its project.
    func layout(for source: SidebarItem) -> SidebarDragLayout? {
        let sidebar = model.sidebar
        guard !sidebar.isFiltering else {
            return nil
        }
        let projects = sidebar.sections.map { section in
            SidebarDragLayout.Project(
                id: section.id,
                acceptsNodes: section.project.document != nil && !section.project.isReadOnly,
                isExpanded: model.isExpanded(section.id),
                items: section.items
            )
        }
        return SidebarDragLayout.make(source: source, projects: projects) { [model] in model.isExpanded(folder: $1, in: $0) }
    }

    // MARK: - The row's gesture

    func sourceChanged(_ item: SidebarItem) {
        guard isIdle, let layout = layout(for: item) else {
            return
        }
        let session = SidebarDragSession(source: item, sourceNodes: layout.sourceNodes)
        withAnimation(animation) {
            state = .active(session)
        }
        if let pending = pendingMonitorLocation {
            pendingMonitorLocation = nil
            session.location = global(pending)
            updateCandidate(reason: .pointer)
        }
    }

    func sourceEnded(_ item: SidebarItem) {
        switch state {
        case .active(let session) where session.source == item:
            finish(session.id)
        case .cancelledUntilMouseUp:
            clear()
        case .active, .idle:
            break
        }
    }

    // MARK: - The event monitor

    /// `location` is in the list's own coordinates, as the monitor sees it.
    func monitorMoved(to location: CGPoint) {
        switch state {
        case .idle:
            pendingMonitorLocation = location
        case .active(let session):
            let point = global(location)
            if let last = session.location, abs(last.x - point.x) <= 0.5, abs(last.y - point.y) <= 0.5 {
                return
            }
            session.location = point
            updateCandidate(reason: .pointer)
        case .cancelledUntilMouseUp:
            break
        }
    }

    func monitorMouseUp(at location: CGPoint) {
        switch state {
        case .active(let session):
            session.location = global(location)
            updateCandidate(reason: .pointer)
            session.freeze(candidate)
            // The row's gesture usually ends the drag first; this ends one whose row scrolled away with its gesture.
            let id = session.id
            Task { @MainActor in self.finish(id) }
        case .cancelledUntilMouseUp(let id):
            Task { @MainActor in
                if case .cancelledUntilMouseUp(id) = self.state {
                    self.clear()
                }
            }
        case .idle:
            pendingMonitorLocation = nil
        }
    }

    /// Cancels the drag but keeps the latch until the mouse comes up.
    func escape() {
        guard case .active(let session) = state else {
            return
        }
        cancelSpringLoad()
        geometryMissToken = nil
        pendingMonitorLocation = nil
        withAnimation(animation) {
            candidate = nil
            state = .cancelledUntilMouseUp(session.id)
        }
    }

    /// Drops the drag outright: the pointer came up unseen, the window lost focus, or the list went away, began a
    /// rename, or started filtering.
    func teardown() {
        guard !isIdle || candidate != nil || pendingMonitorLocation != nil else {
            return
        }
        clear()
    }

    func autoscrolled() {
        updateCandidate(reason: .geometry)
    }

    // MARK: - Geometry

    /// Takes one publication of the list's geometry, as every layout pass sends; nothing observed changes unless the
    /// list resized or the drop target did.
    func geometryChanged(_ geometry: SidebarDragGeometry) {
        frames = geometry.rows
        if let origin = geometry.list?.origin, origin != listOrigin {
            listOrigin = origin
        }
        if geometry.visible != visibleFrame {
            visibleFrame = geometry.visible
        }
        guard case .active = state else {
            return
        }
        updateCandidate(reason: .geometry)
    }

    /// `location`, in the monitor's coordinates, which start at the list's top-left corner, in the window's.
    private func global(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x + listOrigin.x, y: location.y + listOrigin.y)
    }

    private func updateCandidate(reason: UpdateReason) {
        guard case .active(let session) = state, let location = session.location, let visible = visibleFrame else {
            geometryMissToken = nil
            setCandidate(nil)
            return
        }
        guard let layout = layout(for: session.source) else {
            // The dragged item went: deleted, moved by an agent, or its project became read-only.
            clear()
            return
        }
        let next = sidebarDropCandidate(at: location, layout: layout, frames: frames, visible: visible, retaining: candidate?.target)
        if reason == .geometry, let current = candidate, next?.target != current.target {
            scheduleGeometryMiss(for: session.id)
            return
        }
        geometryMissToken = nil
        setCandidate(next)
    }

    private func setCandidate(_ next: SidebarDropCandidate?) {
        guard next != candidate else {
            return
        }
        // A line moving from place to place jumps; one appearing or going fades.
        if next != nil, candidate != nil {
            candidate = next
        } else {
            withAnimation(animation) {
                candidate = next
            }
        }
        updateSpringLoad()
    }

    /// Waits out one grace period, never extended, for the full set of frames to confirm a target change.
    private func scheduleGeometryMiss(for sessionID: UUID) {
        guard geometryMissToken == nil else {
            return
        }
        let token = UUID()
        geometryMissToken = token
        let sleep = system.sleep
        Task { @MainActor [weak self] in
            try? await sleep(Self.geometryGrace)
            guard let self, self.geometryMissToken == token, self.state.session?.id == sessionID else {
                return
            }
            self.geometryMissToken = nil
            self.updateCandidate(reason: .pointer)
        }
    }

    // MARK: - Opening a closed folder or project

    private func updateSpringLoad() {
        var target: SidebarItem?
        if let candidate, candidate.opensAfterPause, case .into(let item) = candidate.target {
            target = item
        }
        guard springLoad?.target != target else {
            return
        }
        cancelSpringLoad()
        guard let target, let sessionID = state.session?.id else {
            return
        }
        let sleep = system.sleep
        let task = Task { @MainActor [weak self] in
            guard (try? await sleep(Self.springLoadDelay)) != nil, !Task.isCancelled else {
                return
            }
            self?.springOpen(target, sessionID: sessionID)
        }
        springLoad = (target, task)
    }

    private func springOpen(_ item: SidebarItem, sessionID: UUID) {
        springLoad = nil
        guard state.session?.id == sessionID, candidate?.target == .into(item) else {
            return
        }
        withAnimation(animation) {
            expand(item)
        }
    }

    private func cancelSpringLoad() {
        springLoad?.task.cancel()
        springLoad = nil
    }

    private func expand(_ item: SidebarItem) {
        switch item {
        case .project(let project):
            model.setExpanded(true, project: project)
        case .node(let project, let folder):
            model.setExpanded(true, folder: folder, in: project)
        }
    }

    // MARK: - Ending

    private func finish(_ sessionID: UUID) {
        guard case .active(let session) = state, session.id == sessionID else {
            return
        }
        session.freeze(candidate)
        clear()
        if let target = session.frozenCandidate?.target {
            commit(session.source, to: target)
        }
    }

    private func clear() {
        cancelSpringLoad()
        geometryMissToken = nil
        pendingMonitorLocation = nil
        withAnimation(animation) {
            if state != .idle {
                state = .idle
            }
            if candidate != nil {
                candidate = nil
            }
        }
    }

    /// A move into another project asks first (`AppModel.requestMove`); every move reveals where it landed.
    private func commit(_ source: SidebarItem, to target: SidebarDropTarget) {
        switch (source, target) {
        case (.project(let project), .project(let index)):
            model.moveProject(project, to: index)
        case (.node(let project, let node), .node(let destination, let parent, let index)):
            model.requestMove(node, from: project, to: destination, into: parent, at: index)
        case (.node(let project, let node), .into(let container)):
            model.requestMove(node, from: project, to: container.projectID, into: container.nodeID, at: 0)
        case (.project, .node), (.project, .into), (.node, .project):
            break
        }
    }
}
