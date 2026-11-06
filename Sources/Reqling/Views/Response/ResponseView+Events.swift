import ReqlingKit
import SwiftUI

/// An event-stream response's Events tab, in place of its Body: the events on a timeline, as one tree or as text, with
/// what the stream left out above them and how it ended below.
struct ResponseEventsView: View {
    @Bindable var response: ResponseViewModel
    let stream: EventStreamRecord
    /// A stored run that `RunHistoryStore` cut to fit.
    let isCacheShortened: Bool

    var body: some View {
        let notes = MessageTimelineView.notes(
            trimmedCount: stream.trimmedEntryCount,
            droppedCount: stream.droppedEventCount,
            isCacheShortened: isCacheShortened,
            kind: .stream
        )
        let end = MessageTimelineEnd(
            isOpen: stream.end == nil,
            isEmpty: stream.entries.isEmpty,
            kind: .stream,
            ending: Self.ending(of: stream),
            endsInFailure: stream.end?.isFailure == true
        )
        if response.eventsMode == .tree, let tree = response.eventTree {
            MessageTimelineTreeView(
                structure: tree,
                notes: notes,
                end: end,
                search: response.search,
                controller: response.treeController,
                accessibilityLabel: "Events"
            )
        } else {
            MessageTimelineView(entries: response.eventTimeline, notes: notes, end: end)
        }
    }

    /// How the stream ended, in a sentence; `nil` while it is open.
    static func ending(of stream: EventStreamRecord) -> String? {
        let ending: String? = switch stream.end {
        case nil: nil
        case .closed: "Closed by the server."
        case .stopped: "Stopped."
        case .limit: "Stopped at the agent's limit."
        case .timedOut: "Ended after no data for longer than the request's timeout."
        case .failed(let message): "Ended: \(message)"
        }
        guard let ending else {
            return nil
        }
        return stream.eventCount == 0 ? "No events arrived. \(ending)" : ending
    }
}

/// The Events tab's Tree and Text picker, the tree's Expand All and Collapse All, and its copy and save actions.
struct ResponseEventsControls: View {
    @Bindable var response: ResponseViewModel
    /// Puts the picker and the actions at opposite ends, for the row of their own under the tabs.
    let spreads: Bool
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            SectionPicker("Format", selection: $response.eventsMode, options: MessageTimelineMode.allCases, label: \.rawValue)
            if spreads {
                Spacer(minLength: 0)
            }
            // Icon tiles carry their own padding, so they sit closer together than the row's other controls.
            HStack(spacing: 2) {
                if response.eventsMode == .tree {
                    BodyTreeControls(controller: response.treeController)
                }
                Button {
                    response.copyBody(to: model.system)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy the events")
                .accessibilityLabel("Copy the events")
                Button {
                    response.saveBody(with: model.system)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Save the events to a file")
                .accessibilityLabel("Save the events to a file")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}
