import ReqlingKit
import SwiftUI

/// Every message or event, in the order they crossed the wire, with what went wrong above them. Notes above the
/// entries say what is left out, by cause: a long run keeps only its newest entries, one too fast to record loses some
/// in between, and a saved response may have been shortened to fit the run history.
///
/// A live timeline opens at its end and follows the newest entries, and scrolling away pauses following; a finished one
/// opens at the top. Either raises Jump to Bottom while away from its end, and that, or scrolling back, takes it to the
/// newest entry, where a live one follows again. Callers key it by run, so each run starts afresh.
struct MessageTimelineView: View {
    let entries: [MessageTimelineEntry]
    /// What went wrong, in red above the entries: a failed call's status message.
    let failure: String?
    let notes: [String]
    let end: MessageTimelineEnd
    @State private var position: ScrollPosition
    /// Keeps to the newest entry: a live timeline from the start, and either kind once Jump to Bottom, or the person's
    /// own scroll, reaches its end. Only the person's scrolling clears it: a lazy stack's height is an estimate until
    /// its rows lay out, so judged by position alone a jump to the end, or a batch of new entries, could clear it
    /// mid-scroll and leave a live timeline stuck short of its end.
    @State private var follows: Bool
    /// Whether the list shows its end, as its geometry reads now.
    @State private var isAtEnd = true
    /// The person is scrolling (a drag, a swipe, or the wheel, and its deceleration), never a programmatic scroll.
    @State private var isUserScrolling = false

    init(entries: [MessageTimelineEntry], failure: String? = nil, notes: [String] = [], end: MessageTimelineEnd) {
        self.entries = entries
        self.failure = failure
        self.notes = notes
        self.end = end
        _follows = State(initialValue: end.isOpen)
        // A live one starts at its end line, by ID, for the reason `scrollToEnd` gives.
        _position = State(initialValue: end.isOpen ? ScrollPosition(id: Self.endID, anchor: .bottom) : ScrollPosition(edge: .top))
    }

    var body: some View {
        // Not while following: a growing list, or one mid-jump, reads as away from its end until the scroll lands.
        let showsJump = !follows && !isAtEnd
        following(
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    MessageTimelineNotes(failure: failure, notes: notes)
                    ForEach(entries) { entry in
                        MessageTimelineRow(entry: entry)
                            .equatable()
                    }
                    end
                        .id(Self.endID)
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .scrollPosition($position)
        )
        .overlay(alignment: .bottom) {
            if showsJump {
                JumpToBottomButton {
                    follows = true
                    scrollToEnd()
                }
            }
        }
        .animation(.snappy, value: showsJump)
    }

    /// What the timeline leaves out, by cause.
    static func notes(trimmedCount: Int, droppedCount: Int, isCacheShortened: Bool, kind: MessageTimelineKind) -> [String] {
        var notes: [String] = []
        if isCacheShortened {
            notes.append("This saved response was shortened to fit the run history.")
        }
        if trimmedCount > 0 {
            let earlier = trimmedCount == 1 ? "1 earlier \(kind.singular)" : "\(trimmedCount) earlier \(kind.plural)"
            // A shortened saved response explains its own trimming; otherwise it is the record's window.
            notes.append(isCacheShortened ? "\(earlier) not shown." : "\(earlier) not shown; \(kind.windowNote).")
        }
        if droppedCount > 0 {
            notes.append("\(kind.count(droppedCount)) skipped while Reqling fell behind.")
        }
        return notes
    }

    /// Only the person's scrolling pauses or resumes following, as it leaves or reaches the end and where it comes to
    /// rest; programmatic scrolls never do. A resize keeps a live timeline that follows at its end: the pane growing or
    /// shrinking moves its bottom, which is not scrolling away.
    private func following<Content: View>(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    visibleHeight: geometry.containerSize.height
                )
            } action: { old, new in
                isAtEnd = new.isAtEnd
                if isUserScrolling {
                    follows = new.isAtEnd
                } else if old.visibleHeight != new.visibleHeight, follows, end.isOpen {
                    scrollToEnd()
                }
            }
            .onScrollPhaseChange { _, phase in
                let wasScrolling = isUserScrolling
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if wasScrolling, !isUserScrolling {
                    follows = isAtEnd
                }
            }
            .onChange(of: entries.last?.id) {
                if follows, end.isOpen {
                    scrollToEnd()
                }
            }
            // A run can first draw before it reads as live, which set `follows` from that frame; once it does, it
            // follows from its end. One that ends while followed shows how it ended.
            .onChange(of: end.isOpen) { _, isOpen in
                if isOpen {
                    follows = true
                }
                if follows {
                    scrollToEnd()
                }
            }
    }

    private static let endID = "end"

    /// To the last view by its ID, not the content's bottom edge: a lazy stack's height is an estimate until its rows
    /// lay out, so a long list of tall rows scrolled to its edge stopped short of the end. The end line, or the last
    /// entry when that line shows nothing.
    private func scrollToEnd() {
        if end.isShown {
            position.scrollTo(id: Self.endID, anchor: .bottom)
        } else if let last = entries.last {
            position.scrollTo(id: last.id, anchor: .bottom)
        } else {
            position.scrollTo(edge: .bottom)
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

    /// Whether it draws anything: a finished call with messages has nothing to add after them.
    var isShown: Bool {
        isOpen || ending != nil
    }

    var body: some View {
        if isOpen {
            // The status bar's Streaming… already moves; this only marks where new entries land.
            Label(isEmpty ? "Waiting for \(kind.awaited)…" : "Waiting for more \(kind.awaited)…", systemImage: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let ending {
            Text(ending)
                .foregroundStyle(endsInFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        }
    }
}

/// A timeline in Tree mode: its notes, then one tree with a row per message or event over its fields. Live, it opens
/// at its end and follows like the Text timeline; either way, it raises the same Jump to Bottom while scrolled away
/// from its end. A search pauses following until its find bar closes, so the button stays away meanwhile.
struct MessageTimelineTreeView: View {
    let structure: BodyStructure
    var failure: String?
    let notes: [String]
    let end: MessageTimelineEnd
    @Bindable var search: BodySearchModel
    let controller: BodyTreeController
    let accessibilityLabel: String
    @State private var isAtEnd = true

    var body: some View {
        let showsJump = !isAtEnd && !search.isPresented
        VStack(alignment: .leading, spacing: 8) {
            MessageTimelineNotes(failure: failure, notes: notes)
            end
            BodyTreePane(
                structure: structure,
                search: search,
                controller: controller,
                accessibilityLabel: accessibilityLabel,
                isLive: end.isOpen,
                onScrolledToEndChange: { isAtEnd = $0 }
            )
            .overlay(alignment: .bottom) {
                if showsJump {
                    JumpToBottomButton {
                        controller.scrollToEnd()
                    }
                }
            }
            .animation(.snappy, value: showsJump)
        }
    }
}

/// Brings a timeline scrolled away from its end back to its newest entry, where a live one follows again. It rises from
/// the pane's bottom edge while the timeline is scrolled away, and sinks back once it is at its end.
struct JumpToBottomButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label("Jump to Bottom", systemImage: "arrow.down")
        }
        .buttonStyle(JumpToBottomStyle())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .help("Scroll to the newest entry")
        .padding(.bottom, 12)
        // With Reduce Motion on, it fades rather than slides.
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

/// A solid capsule over the timeline, its arrow in the accent and its words in the primary label color: readable
/// in both appearances and with whatever accent the person chose, and the same whether or not its window is key, which
/// `.borderedProminent` is not (macOS draws that gray in an inactive window).
private struct JumpToBottomStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        JumpToBottomPill(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// The pill itself, tinting under the pointer and more while pressed.
private struct JumpToBottomPill<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: Content
    @Environment(\.appAccent) private var accent
    @State private var isHovered = false

    /// Circular ends: a continuous capsule's border flattens where each end turns, which reads as a stray line.
    private let shape = Capsule(style: .circular)

    var body: some View {
        content
            .labelStyle(JumpToBottomLabelStyle(accent: Color(nsColor: accent)))
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                // The tint over the fill, beneath the words.
                ZStack {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                    shape.fill(Color.primary.opacity(isPressed ? 0.12 : isHovered ? 0.06 : 0))
                }
            }
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }
}

/// The arrow in the accent beside the words.
private struct JumpToBottomLabelStyle: LabelStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(accent)
            configuration.title
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
                Image(systemName: symbol)
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
                        .accessibilityLabel(accessibilityLabel)
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
        entry.item.header.direction == .sent
    }

    /// A ping, pong, or close frame takes a smaller glyph than a message: it carries no payload worth reading.
    private var symbol: String {
        if case .control = entry.item.header {
            return isSent ? "arrow.up.circle" : "arrow.down.circle"
        }
        return isSent ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    /// A message's direction (and a WebSocket's format), an event's type, or a control frame's direction.
    private var title: String {
        switch entry.item.header {
        case .grpc(let direction, _): direction == .sent ? "Sent" : "Received"
        case .event(let type, _): type
        case .webSocket(let direction, let format, let isBase64):
            "\(direction == .sent ? "Sent" : "Received") \(format == .binary ? "binary" : "text")\(isBase64 ? ", base64" : "")"
        case .control(let direction): direction == .sent ? "Sent" : "Received"
        case .note: ""
        }
    }

    private var accessibilityLabel: String {
        switch entry.item.header {
        case .event: "\(title) event"
        case .control: "\(title) frame"
        case .grpc, .webSocket, .note: "\(title) message"
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
                .help(origin)
            if !isControl {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .binary))
                    .foregroundStyle(.secondary)
            }
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

    private var origin: String {
        switch item.header {
        case .grpc, .note: MessageTimelineKind.call.origin
        case .event: MessageTimelineKind.stream.origin
        case .webSocket, .control: MessageTimelineKind.connection.origin
        }
    }

    private var isControl: Bool {
        if case .control = item.header {
            return true
        }
        return false
    }
}
