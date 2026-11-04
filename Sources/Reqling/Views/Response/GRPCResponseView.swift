import ReqlingKit
import SwiftUI

/// The latest call of the selected gRPC request, live while it streams.
struct GRPCResponseView: View {
    @Bindable var response: GRPCResponseViewModel

    var body: some View {
        let exchange = response.exchange
        VStack(spacing: 0) {
            GRPCResponseStatusBar(exchange: exchange, isSending: response.isSending)
            Divider()
            content(exchange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ exchange: RequestExchange?) -> some View {
        if let failure = exchange?.failure {
            ResponseFailureView(failure: failure)
        } else if let call = exchange?.grpc {
            VStack(alignment: .leading, spacing: 8) {
                SectionPicker("Response section", selection: $response.tab, options: GRPCResponseTab.allCases, label: \.rawValue)
                GRPCResponseTabContent(response: response, call: call)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, AppMetrics.detailPaneInset)
            .padding(.vertical, AppMetrics.paneInset)
        } else if response.isSending {
            ProgressView("Connecting…")
        } else {
            ContentUnavailableView("No Response Yet", systemImage: "paperplane", description: Text("Send the request to see its messages here."))
        }
    }
}

/// The status by name, or Streaming… while the call is open, then its time and how many messages crossed each way.
private struct GRPCResponseStatusBar: View {
    let exchange: RequestExchange?
    let isSending: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let call = exchange?.grpc {
                if let status = call.status {
                    GRPCStatusBadge(status: status)
                } else {
                    Label("Streaming…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(GRPCBadge.color)
                }
                ResponseMetric(label: "Time", value: ResponseStatusBar.duration(call.duration))
                // Totals, omitted messages included; the timeline says which it leaves out and why.
                ResponseMetric(label: "Sent", value: "\(call.sentCount)")
                ResponseMetric(label: "Received", value: "\(call.receivedCount)")
                if call.trimmedEventCount > 0 {
                    ResponseMetric(label: "Earlier", value: "\(call.trimmedEventCount)")
                        .help("Older messages not kept; a call keeps its newest \(GRPCCallRecord.eventLimit), or as many as fit its size limit")
                }
            } else if exchange?.failure != nil {
                Label("Failed", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            } else {
                Text("Response")
                    .font(.headline)
            }
            Spacer()
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Sending")
            }
            if let environment = exchange?.environmentName {
                ResponseEnvironmentLabel(name: environment)
            }
        }
        .padding(.horizontal, AppMetrics.detailPaneInset)
        .padding(.vertical, 8)
    }
}

private struct GRPCResponseTabContent: View {
    let response: GRPCResponseViewModel
    let call: GRPCCallRecord

    var body: some View {
        switch response.tab {
        case .messages:
            GRPCTimelineView(
                entries: response.timeline,
                status: call.status,
                trimmedCount: call.trimmedEventCount,
                droppedCount: call.droppedEventCount,
                isCacheShortened: response.exchange?.isBodyTruncated == true
            )
        case .metadata:
            GRPCMetadataView(initial: call.initialMetadata, trailers: call.trailers, isOpen: call.status == nil)
        case .request:
            GRPCCallRequestView(call: call)
        }
    }
}

/// Initial metadata as the server sent it, and the trailers that ended the call.
private struct GRPCMetadataView: View {
    let initial: [KeyValuePair]
    let trailers: [KeyValuePair]
    let isOpen: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Initial metadata", rows: initial, empty: isOpen ? "Not received yet." : "None.")
                section("Trailers", rows: trailers, empty: isOpen ? "Received when the call ends." : "None.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, rows: [KeyValuePair], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
            } else {
                HeaderGrid(headers: rows)
            }
        }
    }
}

/// What the call was sent to, with secrets masked.
private struct GRPCCallRequestView: View {
    let call: GRPCCallRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("Target") {
                    Text(call.target)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledRow("Method") {
                    HStack(spacing: 8) {
                        Text(call.method)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        GRPCMethodKindBadge(kind: call.kind)
                    }
                }
                Text("Metadata")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 6)
                if call.sentMetadata.isEmpty {
                    Text("None.")
                        .foregroundStyle(.secondary)
                } else {
                    HeaderGrid(headers: call.sentMetadata)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
