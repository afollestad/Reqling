import CoreGraphics
import ReqlingKit

/// What a drop does once the drag ends.
enum SidebarDropTarget: Hashable {
    /// Puts the dragged project at `index` among the others, counted without it.
    case project(index: Int)
    /// Puts the dragged folder or request under `parent` (`nil` for the top level) of a project, at `index` in its
    /// children counted without it.
    case node(ProjectID, parent: RequestNodeID?, index: Int)
    /// Puts the dragged folder or request first inside a folder or project.
    case into(SidebarItem)
}

/// A drop target and what shows it: Alveary's convention of a line for a place in an order, and a border for a
/// container. All geometry is in the sidebar's drag coordinate space (`SidebarDragGeometry`).
struct SidebarDropCandidate: Equatable {
    let target: SidebarDropTarget
    /// The insertion line's leading end, indented to the level it inserts at.
    var line: CGPoint?
    /// The vertical span the border wraps: the folder or project row and its open contents.
    var border: CGRect?
    /// A closed folder or project, which opens if the pointer rests on it (`SidebarDragController`).
    var opensAfterPause = false
}

enum SidebarDropMetrics {
    /// A folder's top and bottom share of its row that inserts beside it; the middle drops into it.
    static let folderEdgeFraction: CGFloat = 0.25
    /// How far the pointer can stray before a target gives way to its neighbour, so a line resting on a boundary
    /// between two targets, in either axis, doesn't flicker.
    static let retentionSlop: CGFloat = 4
    /// The line's inset from the sidebar's edges where it isn't indented, as Alveary's is.
    static let lineInset: CGFloat = 10
}

/// The drop under `point`, or `nil` where a drop would do nothing.
///
/// `retaining` is the current target: it holds while the pointer is within `SidebarDropMetrics.retentionSlop` of
/// somewhere that still resolves to it, measured on the current geometry, so it survives scrolling and rows moving. A
/// drop into a folder or project takes over as soon as the pointer is inside it, as Alveary's containers do; held off by
/// the slop, a folder's middle, half its row, would barely be reachable from the lines either side of it.
func sidebarDropCandidate(
    at point: CGPoint,
    layout: SidebarDragLayout,
    frames: [SidebarItem: CGRect],
    visible: CGRect,
    retaining: SidebarDropTarget?
) -> SidebarDropCandidate? {
    let resolver = SidebarDropResolver(layout: layout, frames: frames, visible: visible)
    let fresh = resolver.candidate(at: point)
    if case .into = fresh?.target {
        return fresh
    }
    guard let retaining, fresh?.target != retaining, visible.contains(point) else {
        return fresh
    }
    let slop = SidebarDropMetrics.retentionSlop
    for offset in [CGSize(width: -slop, height: 0), CGSize(width: slop, height: 0), CGSize(width: 0, height: -slop), CGSize(width: 0, height: slop)] {
        let probe = CGPoint(x: point.x + offset.width, y: point.y + offset.height)
        if let held = resolver.candidate(at: probe), held.target == retaining {
            return held
        }
    }
    return fresh
}

/// Resolves points against one layout and one set of row frames.
///
/// Each mounted row owns a band reaching halfway to the rows shown either side of it, the dragged ones included, so the
/// gaps between rows still hit a row; the first and last reach past the viewport. Zones divide that band, the row's
/// content frame plus half the gap either side, since the frame alone is only the row's text height. Folders and
/// requests split it:
/// - a request: the upper half inserts above it, the lower half below;
/// - a folder: the top quarter inserts above it; the middle, or with open contents everything below that, drops into
///   it; a closed or empty folder's bottom quarter inserts below it;
/// - a project row: drops into it.
///
/// An insertion below a row may be at any level from the next row's up to its own, picked by the pointer's x, as an
/// outline view does, so the end of an open folder reaches both its last place and the place after it.
private struct SidebarDropResolver {
    private struct Mounted {
        let index: Int
        let frame: CGRect
        /// The band it takes hits in; the first and last are open-ended.
        let top: CGFloat
        let bottom: CGFloat
        /// The span its zones divide: the band, closed off past the end rows by mirroring the gap on their inner side.
        let zoneTop: CGFloat
        let zoneBottom: CGFloat
    }

    let layout: SidebarDragLayout
    let frames: [SidebarItem: CGRect]
    let visible: CGRect
    private let mounted: [Mounted]
    /// Where a top-level folder's or request's content starts; each level indents `SidebarNodeRow.indentPerLevel`.
    private let nodeBaseX: CGFloat?
    /// The dragged rows' extent, which takes no drop.
    private let draggedSpan: ClosedRange<CGFloat>?

    init(layout: SidebarDragLayout, frames: [SidebarItem: CGRect], visible: CGRect) {
        self.layout = layout
        self.frames = frames
        self.visible = visible
        // Every row shown, dragged ones too: a band stopping halfway to a dragged row leaves that row's slot to it.
        let shown = frames.values.sorted { $0.minY < $1.minY }
        let present = layout.rows.indices.compactMap { index in frames[layout.rows[index].item].map { (index, $0) } }
        mounted = present.map { index, frame in
            let position = shown.firstIndex(of: frame) ?? 0
            let above = position == 0 ? nil : (shown[position - 1].maxY + frame.minY) / 2
            let below = position == shown.count - 1 ? nil : (frame.maxY + shown[position + 1].minY) / 2
            let zoneTop = above ?? below.map { frame.minY - ($0 - frame.maxY) } ?? frame.minY
            let zoneBottom = below ?? above.map { frame.maxY + (frame.minY - $0) } ?? frame.maxY
            return Mounted(
                index: index, frame: frame, top: above ?? -.infinity, bottom: below ?? .infinity, zoneTop: zoneTop, zoneBottom: zoneBottom
            )
        }
        nodeBaseX = present.first { layout.rows[$0.0].depth >= 0 }?.1.minX
        let dragged = frames.filter { layout.isDragged($0.key) }.values
        draggedSpan = dragged.isEmpty ? nil : (dragged.map(\.minY).min() ?? 0)...(dragged.map(\.maxY).max() ?? 0)
    }

    func candidate(at point: CGPoint) -> SidebarDropCandidate? {
        guard visible.contains(point), draggedSpan?.contains(point.y) != true,
              let hit = mounted.first(where: { point.y >= $0.top && point.y < $0.bottom }) else {
            return nil
        }
        let fraction = (point.y - hit.zoneTop) / max(hit.zoneBottom - hit.zoneTop, 1)
        switch layout.source {
        case .project:
            return projectCandidate(at: hit.index, fraction: fraction, pointerY: point.y)
        case .node:
            return nodeCandidate(at: hit.index, fraction: fraction, pointer: point)
        }
    }

    // MARK: - Folders and requests

    private func nodeCandidate(at index: Int, fraction: CGFloat, pointer: CGPoint) -> SidebarDropCandidate? {
        let row = layout.rows[index]
        switch row.kind {
        case .project(let isExpanded):
            return row.acceptsNodes ? into(index, opens: !isExpanded) : nil
        case .request:
            return gap(after: fraction < 0.5 ? index - 1 : index, pointer: pointer)
        case .folder(let isExpanded, let hasVisibleChildren):
            let edge = SidebarDropMetrics.folderEdgeFraction
            if fraction < edge {
                return gap(after: index - 1, pointer: pointer)
            }
            if hasVisibleChildren || fraction <= 1 - edge {
                return into(index, opens: !isExpanded)
            }
            return gap(after: index, pointer: pointer)
        }
    }

    /// An insertion between `rows[aboveIndex]` and the row after it, at the level the pointer's x picks.
    private func gap(after aboveIndex: Int, pointer: CGPoint) -> SidebarDropCandidate? {
        let rows = layout.rows
        guard rows.indices.contains(aboveIndex), rows[aboveIndex].acceptsNodes else {
            return nil
        }
        let above = rows[aboveIndex]
        let project = above.item.projectID
        let below = rows.indices.contains(aboveIndex + 1) ? rows[aboveIndex + 1] : nil
        let level: Int
        let target: SidebarDropTarget
        if above.depth < 0 {
            // Below a project's row is its first place.
            level = 0
            target = .node(project, parent: nil, index: 0)
        } else {
            let lowest = below.flatMap { $0.depth >= 0 && $0.item.projectID == project ? $0.depth : nil } ?? 0
            let highest = max(above.depth, lowest)
            let pointed = nodeBaseX.map { Int(((pointer.x - $0) / SidebarNodeRow.indentPerLevel).rounded(.down)) } ?? highest
            level = min(max(pointed, lowest), highest)
            if level > above.depth {
                // `above` is an open folder and `below` its first child.
                target = .node(project, parent: above.item.nodeID, index: 0)
            } else {
                // Every row between `above`'s ancestor at `level` and `above` is deeper, so the nearest one at `level`
                // is that ancestor, or `above` itself.
                guard let anchor = rows[...aboveIndex].last(where: { $0.depth == level }) else {
                    return nil
                }
                target = .node(project, parent: anchor.parent, index: anchor.index + 1)
            }
        }
        guard !isOrigin(target) else {
            return nil
        }
        let indent = nodeBaseX.map { $0 + CGFloat(level) * SidebarNodeRow.indentPerLevel } ?? visible.minX + SidebarDropMetrics.lineInset
        return SidebarDropCandidate(target: target, line: CGPoint(x: indent, y: boundaryY(after: aboveIndex, pointerY: pointer.y)))
    }

    /// A drop into a folder or project, puts it first.
    private func into(_ index: Int, opens: Bool) -> SidebarDropCandidate? {
        let row = layout.rows[index]
        guard !isOrigin(.node(row.item.projectID, parent: row.item.nodeID, index: 0)), let frame = frames[row.item] else {
            return nil
        }
        // Its open contents: the rows after it that are deeper, up to the next project.
        let rows = layout.rows
        let end = rows[(index + 1)...].firstIndex { $0.depth <= row.depth } ?? rows.count
        let contents = rows[(index + 1)..<end].compactMap { frames[$0.item] }
        var bottom = contents.map(\.maxY).max() ?? frame.maxY
        if let last = rows[(index + 1)..<end].last, frames[last.item] == nil {
            // The end of its contents is scrolled away below.
            bottom = visible.maxY
        }
        let border = CGRect(x: visible.minX, y: frame.minY, width: visible.width, height: bottom - frame.minY)
        return SidebarDropCandidate(target: .into(row.item), border: border, opensAfterPause: opens)
    }

    // MARK: - Projects

    /// A dragged project inserts only at another project's edges: above its row, or below its last open row.
    private func projectCandidate(at index: Int, fraction: CGFloat, pointerY: CGFloat) -> SidebarDropCandidate? {
        let rows = layout.rows
        guard let headerIndex = rows[...index].lastIndex(where: { $0.depth < 0 }) else {
            return nil
        }
        let lastIndex = (rows[(headerIndex + 1)...].firstIndex { $0.depth < 0 } ?? rows.count) - 1
        let projectIndex = rows[headerIndex].index
        let target: SidebarDropTarget
        let boundary: Int
        if index == headerIndex, fraction < 0.5 {
            target = .project(index: projectIndex)
            boundary = headerIndex - 1
        } else if index == lastIndex, fraction >= 0.5 {
            target = .project(index: projectIndex + 1)
            boundary = lastIndex
        } else {
            return nil
        }
        guard !isOrigin(target) else {
            return nil
        }
        let line = CGPoint(x: visible.minX + SidebarDropMetrics.lineInset, y: boundaryY(after: boundary, pointerY: pointerY))
        return SidebarDropCandidate(target: target, line: line)
    }

    // MARK: - Helpers

    /// Halfway between `rows[aboveIndex]` and the row after it, using whichever of the two is mounted. The dragged rows
    /// still show in the gap they left, so where that is the gap, the line keeps to the side of them the pointer is on.
    private func boundaryY(after aboveIndex: Int, pointerY: CGFloat) -> CGFloat {
        let rows = layout.rows
        var upper = rows.indices.contains(aboveIndex) ? frames[rows[aboveIndex].item]?.maxY : nil
        var lower = rows.indices.contains(aboveIndex + 1) ? frames[rows[aboveIndex + 1].item]?.minY : nil
        if let dragged = draggedSpan, dragged.lowerBound >= (upper ?? -.infinity), dragged.upperBound <= (lower ?? .infinity) {
            if pointerY < dragged.lowerBound {
                lower = dragged.lowerBound
            } else {
                upper = dragged.upperBound
            }
        }
        switch (upper, lower) {
        case (let upper?, let lower?): return (upper + lower) / 2
        case (let upper?, nil): return upper
        case (nil, let lower?): return lower
        case (nil, nil): return visible.minY
        }
    }

    private func isOrigin(_ target: SidebarDropTarget) -> Bool {
        switch (target, layout.origin) {
        case (.project(let index), .project(let origin)):
            index == origin
        case (.node(let project, let parent, let index), .node(let originProject, let originParent, let originIndex)):
            project == originProject && parent == originParent && index == originIndex
        default:
            false
        }
    }
}
