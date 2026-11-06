import ReqlingKit
import SwiftUI

/// The selected WebSocket request's connection, live while it is open, the past run picked in its history, or two runs
/// compared.
struct WebSocketResponseView: View {
    @Bindable var response: WebSocketResponseViewModel
    let model: AppModel

    var body: some View {
        let history = response.history
        // One root whichever shows, as in `ResponseView`.
        VStack(spacing: 0) {
            if let pair = history.comparing {
                RunComparisonView(history: history, pair: pair)
            } else {
                connectionView(history)
            }
        }
    }

    private func connectionView(_ history: RunHistoryViewModel) -> some View {
        let exchange = response.exchange
        return VStack(spacing: 0) {
            WebSocketStatusBar(exchange: exchange, isSending: response.isSending, scripts: response.scripts)
            PinnedRunBar(history: history)
            if response.scripts?.isUntrusted == true {
                ScriptsOffNotice(projectID: response.projectID, model: model)
            }
            Divider()
            content(exchange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: history.pinnedRunID) {
            await history.loadPinned()
        }
    }

    @ViewBuilder
    private func content(_ exchange: RequestExchange?) -> some View {
        if let failure = exchange?.failure {
            ResponseFailureView(failure: failure, scripts: response.scripts)
        } else if let record = exchange?.webSocket, record.handshake != nil || record.end != nil {
            VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                WebSocketSectionBar(response: response)
                WebSocketTabContent(response: response, record: record)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, AppMetrics.detailPaneInset)
            .padding(.vertical, AppMetrics.paneInset)
        } else if let status = response.history.pinnedStatus {
            PinnedRunPlaceholder(status: status, history: response.history)
        } else if response.isSending {
            ProgressView("Connecting…")
        } else {
            ContentUnavailableView(
                "Not Connected Yet",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("Connect to see every message both ways here.")
            )
        }
    }
}

/// How the connection stands: open, closed with its code, refused with the server's status, or failed; then its time,
/// how many messages crossed each way, its subprotocol, and its TLS.
private struct WebSocketStatusBar: View {
    let exchange: RequestExchange?
    let isSending: Bool
    let scripts: ScriptReportPresentation?

    var body: some View {
        HStack(spacing: 12) {
            if let record = exchange?.webSocket {
                WebSocketStateBadge(record: record)
                ResponseMetric(label: "Time", value: ResponseStatusBar.duration(record.duration))
                // Totals, omitted messages included; the timeline says which it leaves out and why.
                ResponseMetric(label: "Sent", value: "\(record.sentCount)")
                ResponseMetric(label: "Received", value: "\(record.receivedCount)")
                if let subprotocol = record.subprotocol {
                    ResponseMetric(label: "Subprotocol", value: subprotocol)
                }
                if let handshake = record.handshake, let tlsVersion = handshake.tlsVersion {
                    ResponseMetric(label: "TLS", value: handshake.presentedClientCertificate ? "\(tlsVersion), client certificate" : tlsVersion)
                }
                if record.trimmedEntryCount > 0 {
                    ResponseMetric(label: "Earlier", value: "\(record.trimmedEntryCount)")
                        .help("Older entries not kept; a connection keeps its newest \(WebSocketRecord.entryLimit), or as many as fit its size limit")
                }
            } else if exchange?.failure != nil {
                Label("Failed", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            } else {
                Text("Connection")
                    .font(.headline)
            }
            if let scripts {
                ResponseTestsMetric(scripts: scripts, gotResponse: exchange?.failure == nil)
            }
            Spacer()
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Live")
            }
            if let environment = exchange?.environmentName {
                ResponseEnvironmentLabel(name: environment)
            }
        }
        .padding(.horizontal, AppMetrics.detailPaneInset)
        .padding(.vertical, 8)
    }
}

/// Connecting…, Open, a close's code tinted by outcome, a refusal's HTTP status, or Failed.
private struct WebSocketStateBadge: View {
    let record: WebSocketRecord

    var body: some View {
        if case .refused = record.end, let handshake = record.handshake {
            StatusBadge(statusCode: handshake.statusCode, reason: handshake.reasonPhrase)
        } else if let close = record.close {
            Text(close.title)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(WebSocketBadge.color(forClose: close.code)))
                .help(close.byServer ? "The server closed the connection" : "Reqling closed the connection")
                .accessibilityLabel("Closed with \(close.title)")
        } else if record.end != nil {
            Label(record.isFailure ? "Dropped" : "Closed", systemImage: record.isFailure ? "exclamationmark.octagon.fill" : "xmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(record.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        } else if record.handshake == nil {
            Label("Connecting…", systemImage: "ellipsis.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            Label("Open", systemImage: "dot.radiowaves.left.and.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(WebSocketBadge.color)
        }
    }
}

/// The section tabs; on Messages, the Tree and Text picker and the tree's Expand All and Collapse All share their
/// row when it has room, or take one of their own below it.
private struct WebSocketSectionBar: View {
    @Bindable var response: WebSocketResponseViewModel

    var body: some View {
        if response.shownTab == .messages {
            WidthAdaptive {
                HStack(spacing: 12) {
                    tabs
                    Spacer(minLength: 0)
                    controls
                }
            } fallback: {
                VStack(alignment: .leading, spacing: 8) {
                    tabs
                    controls
                }
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        let testsTitle = response.scripts?.tabTitle ?? WebSocketResponseTab.tests.rawValue
        return SectionPicker("Response section", selection: $response.shownTab, options: response.visibleTabs) { tab in
            tab == .tests ? testsTitle : tab.rawValue
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            SectionPicker("Format", selection: $response.messagesMode, options: MessageTimelineMode.allCases, label: \.rawValue)
            if response.messagesMode == .tree {
                BodyTreeControls(controller: response.treeController)
            }
        }
    }
}

private struct WebSocketTabContent: View {
    let response: WebSocketResponseViewModel
    let record: WebSocketRecord

    var body: some View {
        switch response.shownTab {
        case .messages:
            let notes = MessageTimelineView.notes(
                trimmedCount: record.trimmedEntryCount,
                droppedCount: record.droppedEntryCount,
                isCacheShortened: response.exchange?.isBodyTruncated == true,
                kind: .connection
            )
            let end = MessageTimelineEnd(
                isOpen: record.end == nil,
                isEmpty: record.entries.isEmpty,
                kind: .connection,
                ending: record.end.map { Self.ending($0, record) },
                endsInFailure: record.isFailure
            )
            if response.messagesMode == .tree, let tree = response.messageTree {
                MessageTimelineTreeView(
                    structure: tree,
                    failure: nil,
                    notes: notes,
                    end: end,
                    search: response.search,
                    controller: response.treeController,
                    accessibilityLabel: "Messages"
                )
            } else {
                MessageTimelineView(entries: response.timeline, failure: nil, notes: notes, end: end)
                    .id(response.exchange?.id)
            }
        case .handshake:
            WebSocketHandshakeView(record: record, refusalBody: response.refusalBody)
        case .request:
            WebSocketRequestView(request: response.exchange?.request, url: record.url)
        case .tests:
            if let scripts = response.scripts {
                ScriptReportView(scripts: scripts)
            }
        }
    }

    /// How the connection ended, in a sentence under its last entry.
    private static func ending(_ end: WebSocketRecord.End, _ record: WebSocketRecord) -> String {
        let close = record.close.map { close in
            "\(close.byServer ? "The server" : "Reqling") closed it with \(close.title)\(close.reason.isEmpty ? "" : ": \(close.reason)")."
        }
        switch end {
        case .closed: return close ?? "Closed."
        case .stopped: return close.map { "Disconnected. \($0)" } ?? "Disconnected."
        case .limit: return "Reached the agent's limit. " + (close ?? "")
        case .refused(let message), .failed(let message): return message
        }
    }
}

/// The server's answer to the handshake: its status and headers, and a refusal's body, which usually says why.
private struct WebSocketHandshakeView: View {
    let record: WebSocketRecord
    let refusalBody: TextDocument?
    @State private var search = BodySearchModel()

    var body: some View {
        if let handshake = record.handshake {
            if let refusalBody {
                // A refusal's few headers sit above its body, which takes the rest and scrolls on its own.
                VStack(alignment: .leading, spacing: 10) {
                    head(handshake)
                    CodeViewerPane(document: refusalBody, search: search, accessibilityLabel: "Response body")
                }
            } else {
                ScrollView {
                    head(handshake)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("The server hasn't answered yet.")
                .foregroundStyle(.secondary)
        }
    }

    private func head(_ handshake: HTTPResponseRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(handshake.statusCode) \(handshake.reasonPhrase)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            HeaderGrid(headers: handshake.headers)
        }
    }
}

/// The handshake as sent, with secrets masked; the connection adds its own headers below these.
private struct WebSocketRequestView: View {
    let request: ResolvedHTTPRequest?
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GET \(url)")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            ScrollView {
                HeaderGrid(headers: request?.headers ?? [], scriptChanged: Set(request?.scriptChangedHeaders ?? []))
            }
            Text("The connection also sends Host, Upgrade, Connection, Sec-WebSocket-Key, Sec-WebSocket-Version, and the project's cookies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
