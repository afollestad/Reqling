import ReqlingKit
import SwiftUI

/// What a timeline lists, for the words its notes use and the limit they quote.
enum MessageTimelineKind {
    /// A gRPC call's messages both ways.
    case call
    /// An event stream's events, with notes about its connection between them.
    case stream

    func count(_ count: Int) -> String {
        let noun = self == .call ? "message" : "event"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    var plural: String {
        self == .call ? "messages" : "events"
    }

    /// Why older entries are gone from a record nobody shortened.
    var windowNote: String {
        self == .call
            ? "a call keeps its newest \(GRPCCallRecord.eventLimit), or as many as fit"
            : "a stream keeps its newest \(EventStreamRecord.entryLimit), or as many as fit"
    }
}

/// Every message or event, in the order they crossed the wire, with what went wrong above them. Notes above the
/// entries say what is left out, by cause: a long run keeps only its newest entries, one too fast to record loses some
/// in between, and a saved response may have been shortened to fit the run history.
///
/// While scrolled to the end, new entries keep it there; scrolling away stops following, and scrolling back resumes.
struct MessageTimelineView: View {
    let entries: [MessageTimelineEntry]
    /// What went wrong, in red above the entries: a failed call's status message.
    var failure: String?
    var notes: [String] = []
    let end: MessageTimelineEnd
    @State private var position = ScrollPosition()
    @State private var follows = true

    var body: some View {
        following(
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    MessageTimelineNotes(failure: failure, notes: notes)
                    ForEach(entries) { entry in
                        MessageTimelineRow(entry: entry)
                            .equatable()
                    }
                    end
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .scrollPosition($position)
        )
    }

    /// What the timeline leaves out, by cause.
    static func notes(trimmedCount: Int, droppedCount: Int, isCacheShortened: Bool, kind: MessageTimelineKind) -> [String] {
        var notes: [String] = []
        if isCacheShortened {
            notes.append("This saved response was shortened to fit the run history.")
        }
        if trimmedCount > 0 {
            let earlier = trimmedCount == 1 ? "1 earlier \(kind == .call ? "message" : "event")" : "\(trimmedCount) earlier \(kind.plural)"
            // A shortened saved response explains its own trimming; otherwise it is the record's window.
            notes.append(isCacheShortened ? "\(earlier) not shown." : "\(earlier) not shown; \(kind.windowNote).")
        }
        if droppedCount > 0 {
            notes.append("\(kind.count(droppedCount)) skipped while Reqling fell behind.")
        }
        return notes
    }

    /// Content growing under a list at its end leaves it following; only a scroll, or the pane resizing, decides anew,
    /// since a growing list reads as no longer at its end before the scroll to the new end lands.
    private func following<Content: View>(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    visibleHeight: geometry.containerSize.height
                )
            } action: { old, new in
                if old.offset != new.offset || old.visibleHeight != new.visibleHeight {
                    follows = new.isAtEnd
                }
            }
            .onChange(of: entries.last?.id) {
                if follows {
                    position.scrollTo(edge: .bottom)
                }
            }
    }

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
        let visibleHeight: CGFloat

        /// Within a row's height of the end, so a few points short of it still counts.
        var isAtEnd: Bool {
            offset + visibleHeight >= contentHeight - 24
        }
    }
}

/// Above the entries: what went wrong, then what the timeline leaves out.
struct MessageTimelineNotes: View {
    let failure: String?
    let notes: [String]

    var body: some View {
        if let failure, !failure.isEmpty {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        ForEach(notes, id: \.self) { note in
            Label(note, systemImage: "ellipsis")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Where new entries land while the call or stream is open, or how it ended once it has.
struct MessageTimelineEnd: View {
    let isOpen: Bool
    let isEmpty: Bool
    let kind: MessageTimelineKind
    /// How it ended, shown once it has; `nil` says nothing.
    var ending: String?
    var endsInFailure = false

    var body: some View {
        if isOpen {
            // The status bar's Streaming… already moves; this only marks where new entries land.
            Label(isEmpty ? "Waiting for \(kind.plural)…" : "Waiting for more \(kind.plural)…", systemImage: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let ending {
            Text(ending)
                .foregroundStyle(endsInFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        }
    }
}

/// A timeline in Tree mode: its notes, then one tree with a row per message or event over its fields.
struct MessageTimelineTreeView: View {
    let structure: BodyStructure
    var failure: String?
    let notes: [String]
    let end: MessageTimelineEnd
    @Bindable var search: BodySearchModel
    let controller: BodyTreeController
    let accessibilityLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageTimelineNotes(failure: failure, notes: notes)
            end
            BodyTreePane(structure: structure, search: search, controller: controller, accessibilityLabel: accessibilityLabel)
        }
    }
}

/// One message, event, or note: what it is, when (since the run started), its size, and its text, JSON highlighted.
/// Equatable on its entry, so a growing timeline re-renders only the rows it adds.
private struct MessageTimelineRow: View, Equatable {
    let entry: MessageTimelineEntry
    @Environment(\.appAccent) private var accent

    var body: some View {
        let item = entry.item
        if case .note = item.header {
            Label {
                HStack(spacing: 8) {
                    Text(item.text)
                    Text("+\(ResponseStatusBar.duration(item.offset))")
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isSent ? Color(nsColor: accent) : GRPCBadge.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    MessageTimelineRowHeader(item: item, title: title)
                    Text(highlighted)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                        .accessibilityLabel(isEvent ? "\(title) event" : "\(title) message")
                        .accessibilityValue(item.text)
                }
            }
        }
    }

    /// Compares the entry, which is everything the row renders.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
    }

    private var isSent: Bool {
        if case .grpc(.sent, _) = entry.item.header {
            return true
        }
        return false
    }

    private var isEvent: Bool {
        if case .event = entry.item.header {
            return true
        }
        return false
    }

    /// A message's direction, or an event's type.
    private var title: String {
        switch entry.item.header {
        case .grpc(let direction, _): direction == .sent ? "Sent" : "Received"
        case .event(let type, _): type
        case .note: ""
        }
    }

    /// The JSON in the editor's syntax colors, which are dynamic, so a row follows an appearance change unrebuilt.
    private var highlighted: AttributedString {
        var text = AttributedString(entry.item.text)
        for token in entry.tokens {
            if let range = Range(token.range, in: text) {
                text[range].foregroundColor = Color(nsColor: SyntaxPalette.color(for: token.role))
            }
        }
        return text
    }
}

/// A row's caption: its title, an event's ID, when it arrived, its size, and fields a message's schema lacks.
private struct MessageTimelineRowHeader: View {
    let item: TimelineItem
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
            if case .event(_, let id?) = item.header {
                Text("id \(id)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("+\(ResponseStatusBar.duration(item.offset))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(isEvent ? "Since the request was sent" : "Since the call started")
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .binary))
                .foregroundStyle(.secondary)
            if case .grpc(_, let unknownFieldCount) = item.header, unknownFieldCount > 0 {
                Label(
                    unknownFieldCount == 1 ? "1 unknown field" : "\(unknownFieldCount) unknown fields",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .help("The schema doesn't define these fields, so the JSON leaves them out. The schema may be older than the server's.")
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var isEvent: Bool {
        if case .event = item.header {
            return true
        }
        return false
    }
}
