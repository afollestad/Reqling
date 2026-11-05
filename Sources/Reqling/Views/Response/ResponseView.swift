import ReqlingKit
import SwiftUI

/// The selected request's latest exchange, the past run picked in its history, or two runs compared.
struct ResponseView: View {
    @Bindable var response: ResponseViewModel
    let model: AppModel

    var body: some View {
        let history = response.history
        if let pair = history.comparing {
            RunComparisonView(history: history, pair: pair)
        } else {
            exchangeView(history)
        }
    }

    private func exchangeView(_ history: RunHistoryViewModel) -> some View {
        VStack(spacing: 0) {
            ResponseStatusBar(exchange: response.exchange, isSending: response.isSending)
            PinnedRunBar(history: history)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: history.pinnedRunID) {
            await history.loadPinned()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let exchange = response.exchange {
            if let failure = exchange.failure {
                ResponseFailureView(failure: failure)
            } else if let record = exchange.response {
                let pendingShape = response.body.pendingShape
                VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                    ResponseSectionBar(response: response, model: model)
                    ResponseTabContent(response: response, exchange: exchange, record: record, model: model)
                        // A tab narrower or shorter than the pane (Timing caps its width) would otherwise center the whole stack.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, AppMetrics.detailPaneInset)
                .padding(.vertical, AppMetrics.paneInset)
                // Here rather than on the body tab, so a large body keeps shaping while another tab is shown.
                .task(id: pendingShape) {
                    response.startShaping(pendingShape)
                }
            }
        } else if let status = response.history.pinnedStatus {
            PinnedRunPlaceholder(status: status, history: response.history)
        } else if response.isSending {
            ProgressView("Sending…")
        } else {
            ContentUnavailableView("No Response Yet", systemImage: "paperplane", description: Text("Send the request to see its response here."))
        }
    }
}

struct ResponseStatusBar: View {
    let exchange: RequestExchange?
    let isSending: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let record = exchange?.response {
                StatusBadge(statusCode: record.statusCode, reason: record.reasonPhrase)
                ResponseMetric(label: "Time", value: Self.duration(record.duration))
                ResponseMetric(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(record.body.count), countStyle: .file))
                if let protocolName = record.protocolName {
                    ResponseMetric(label: "Protocol", value: protocolName.uppercased())
                }
                if let tlsVersion = record.tlsVersion {
                    ResponseMetric(label: "TLS", value: record.presentedClientCertificate ? "\(tlsVersion), client certificate" : tlsVersion)
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

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }
}

/// The environment a run resolved its variables against, at the trailing end of a status bar.
struct ResponseEnvironmentLabel: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "square.stack.3d.up")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Sent with the \(name) environment")
    }
}

struct ResponseMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct ResponseFailureView: View {
    let failure: RunFailure

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: failure.kind == .cancelled ? "xmark.circle" : "exclamationmark.triangle")
        } description: {
            Text(failure.message)
                .textSelection(.enabled)
        }
    }

    private var title: String {
        switch failure.kind {
        case .invalidRequest: "The Request Couldn't Be Sent"
        case .tls: "TLS Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed Out"
        case .transport: "The Request Failed"
        }
    }
}
