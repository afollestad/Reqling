import ReqlingKit
import SwiftUI

/// Every message both ways, in the order they crossed the wire, with the status message of a call that failed. Notes
/// above the messages say what is left out, by cause: a long stream keeps only its newest messages, a stream too fast
/// to record loses some in between, and a saved response may have been shortened to fit the cache.
struct GRPCTimelineView: View {
    let entries: [GRPCTimelineEntry]
    let status: GRPCStatusRecord?
    /// The oldest messages, cut to keep the record's window (or the cache's size).
    var trimmedCount = 0
    /// Messages never recorded while Reqling fell behind; they can fall between shown ones.
    var droppedCount = 0
    /// A record restored from the response cache that `ResponseCache` cut to fit.
    var isCacheShortened = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let status, !status.isOK, !status.message.isEmpty {
                    Label(status.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "ellipsis")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    GRPCTimelineRow(entry: entry)
                        .equatable()
                }
                if status == nil {
                    // The status bar's Streaming… already moves; this only marks where new messages land.
                    Label(entries.isEmpty ? "Waiting for messages…" : "Waiting for more messages…", systemImage: "ellipsis.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if entries.isEmpty {
                    Text("No messages crossed the wire.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if isCacheShortened {
            notes.append("This saved response was shortened to fit the cache.")
        }
        if trimmedCount > 0 {
            let earlier = trimmedCount == 1 ? "1 earlier message" : "\(trimmedCount) earlier messages"
            // A shortened saved response explains its own trimming; otherwise it is the record's window.
            let limit = "a call keeps its newest \(GRPCCallRecord.eventLimit), or as many as fit"
            notes.append(isCacheShortened ? "\(earlier) not shown." : "\(earlier) not shown; \(limit).")
        }
        if droppedCount > 0 {
            let skipped = droppedCount == 1 ? "1 message" : "\(droppedCount) messages"
            notes.append("\(skipped) skipped while Reqling fell behind.")
        }
        return notes
    }
}

/// One message: which way it went, when (since the call started), its size, and its JSON highlighted. Equatable on
/// its entry, so a growing timeline re-renders only the rows it adds.
private struct GRPCTimelineRow: View, Equatable {
    let entry: GRPCTimelineEntry
    @Environment(\.appAccent) private var accent

    var body: some View {
        let event = entry.event
        let isSent = event.direction == .sent
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(isSent ? Color(nsColor: accent) : GRPCBadge.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isSent ? "Sent" : "Received")
                        .font(.callout.weight(.semibold))
                    Text("+\(ResponseStatusBar.duration(event.offset))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Since the call started")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(event.byteCount), countStyle: .binary))
                        .foregroundStyle(.secondary)
                    if event.unknownFieldCount > 0 {
                        Label(
                            event.unknownFieldCount == 1 ? "1 unknown field" : "\(event.unknownFieldCount) unknown fields",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .help("The schema doesn't define these fields, so the JSON leaves them out. The schema may be older than the server's.")
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
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
                    .accessibilityLabel("\(isSent ? "Sent" : "Received") message")
                    .accessibilityValue(event.json)
            }
        }
    }

    /// Compares the entry, which is everything the row renders.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
    }

    /// The JSON in the editor's syntax colors, which are dynamic, so a row follows an appearance change unrebuilt.
    private var highlighted: AttributedString {
        var text = AttributedString(entry.event.json)
        for token in entry.tokens {
            if let range = Range(token.range, in: text) {
                text[range].foregroundColor = Color(nsColor: SyntaxPalette.color(for: token.role))
            }
        }
        return text
    }
}
