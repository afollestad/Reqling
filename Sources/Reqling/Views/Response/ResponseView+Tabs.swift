import ReqlingKit
import SwiftUI

/// The section tabs. On the Body tab, the format picker and the copy and save actions sit at the trailing end of the
/// same row when it has room, and on a row of their own below it when it doesn't.
struct ResponseSectionBar: View {
    @Bindable var response: ResponseViewModel
    let model: AppModel

    var body: some View {
        if response.tab == .body {
            let modes = response.body.availableModes
            WidthAdaptive {
                HStack(spacing: 12) {
                    tabs
                    Spacer(minLength: 0)
                    ResponseBodyControls(response: response, modes: modes, spreads: false, model: model)
                }
            } fallback: {
                VStack(alignment: .leading, spacing: 8) {
                    tabs
                    ResponseBodyControls(response: response, modes: modes, spreads: true, model: model)
                }
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        SectionPicker("Response section", selection: $response.tab, options: ResponseTab.allCases, label: \.rawValue)
    }
}

struct ResponseTabContent: View {
    @Bindable var response: ResponseViewModel
    let exchange: RequestExchange
    let record: HTTPResponseRecord
    let model: AppModel

    var body: some View {
        switch response.tab {
        case .body:
            ResponseBodyView(response: response, isTruncated: exchange.isBodyTruncated, model: model)
        case .headers:
            HeaderList(headers: record.headers)
        case .timing:
            TimingView(record: record)
        case .request:
            ResolvedRequestView(request: exchange.request, sentBody: response.sentBody)
        }
    }
}

private struct ResponseBodyView: View {
    @Bindable var response: ResponseViewModel
    let isTruncated: Bool
    let model: AppModel

    var body: some View {
        let presentation = response.body
        VStack(alignment: .leading, spacing: 6) {
            if isTruncated {
                Text("Restored from the last session; only the first 5 MB were kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch presentation.content {
            case .text(let document):
                CodeViewerPane(document: document, search: response.search, accessibilityLabel: "Response body")
            case .tree(let structure):
                BodyTreePane(structure: structure, search: response.search, controller: response.treeController, accessibilityLabel: "Response body")
            case .treeFailed(let message):
                ResponseTreeFailure(message: message) { response.bodyMode = .raw }
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Response image")
            case .binary(let byteCount):
                ContentUnavailableView(
                    "Binary Data",
                    systemImage: "doc.zipper",
                    description: Text("\(Self.size(byteCount)). Save it to open it in another app.")
                )
                // Centered in the pane, not at its ideal width against this stack's leading edge.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView("Empty Body", systemImage: "tray", description: Text("The response had no body."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shaping:
                ProgressView("Formatting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension ResponseBodyView {
    static func size(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// The body's format picker and its copy and save actions.
private struct ResponseBodyControls: View {
    @Bindable var response: ResponseViewModel
    let modes: [ResponseBodyMode]
    /// Puts the picker and the actions at opposite ends, for the row of their own under the tabs.
    let spreads: Bool
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let contentType = response.contentType {
                ResponseContentTypeLabel(contentType: contentType)
            }
            if modes.count > 1 {
                SectionPicker("Format", selection: $response.selectedBodyMode, options: modes, label: \.rawValue)
            }
            if spreads {
                Spacer(minLength: 0)
            }
            // Icon tiles carry their own padding, so they sit closer together than the row's other controls.
            HStack(spacing: 2) {
                if case .tree = response.body.content {
                    BodyTreeControls(controller: response.treeController)
                }
                Button {
                    response.copyBody(to: model.system)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy the body")
                .accessibilityLabel("Copy the body")
                Button {
                    response.saveBody(with: model.system)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Save the body to a file")
                .accessibilityLabel("Save the body to a file")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

/// The response's media type, with the whole Content-Type (charset and all) on hover.
private struct ResponseContentTypeLabel: View {
    let contentType: String

    var body: some View {
        Text(contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? contentType)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(contentType)
            .accessibilityLabel("Content type, \(contentType)")
    }
}

/// Tree mode on a body that doesn't parse as its format.
private struct ResponseTreeFailure: View {
    let message: String
    let onShowRaw: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can't Show a Tree", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Show Raw", action: onShowRaw)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HeaderList: View {
    let headers: [KeyValuePair]

    var body: some View {
        ScrollView {
            HeaderGrid(headers: headers)
        }
    }
}

/// Names and values in two aligned columns: HTTP headers, gRPC metadata and trailers.
struct HeaderGrid: View {
    let headers: [KeyValuePair]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(headers.indices, id: \.self) { index in
                GridRow {
                    Text(headers[index].key)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(headers[index].value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A waterfall of the final transaction's phases.
private struct TimingView: View {
    let record: HTTPResponseRecord
    @Environment(\.appAccent) private var accent

    var body: some View {
        let phases = Self.phases(record.timing)
        let total = max(record.duration, phases.map(\.duration).reduce(0, +), 0.000_001)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(phases, id: \.name) { phase in
                HStack {
                    Text(phase.name)
                        .frame(width: 120, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color(nsColor: accent).opacity(0.7))
                            .frame(width: max(2, proxy.size.width * phase.duration / total))
                    }
                    .frame(height: 8)
                    Text(Self.format(phase.duration))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(Self.format(record.duration)).monospacedDigit()
            }
            if record.timing?.isReusedConnection == true {
                Text("The connection was reused, so DNS, connect, and TLS were skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.redirectCount > 0 {
                Text("Followed \(record.redirectCount) redirect\(record.redirectCount == 1 ? "" : "s"); timing covers the final request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private struct Phase {
        let name: String
        let duration: TimeInterval
    }

    private static func phases(_ timing: HTTPTiming?) -> [Phase] {
        guard let timing else {
            return []
        }
        return [
            ("DNS lookup", timing.dnsLookup),
            ("Connect", timing.connect),
            ("TLS handshake", timing.tlsHandshake),
            ("Request sent", timing.requestSent),
            ("Waiting", timing.waiting),
            ("Download", timing.download)
        ].compactMap { name, duration in duration.map { Phase(name: name, duration: $0) } }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}

/// What was actually sent, with secrets masked.
private struct ResolvedRequestView: View {
    /// The summary lists what Reqling set; the URL loading system adds these below it.
    private static let systemHeadersNote =
        "macOS also adds Host, Content-Length, Accept-Encoding, and Accept-Language, and its own value for any automatic header you turned off."

    let request: ResolvedHTTPRequest?
    let sentBody: TextDocument?
    @State private var search = BodySearchModel()

    var body: some View {
        if let request {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MethodBadge(method: HTTPMethod(rawValue: request.method))
                    Text(request.url)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                HeaderList(headers: request.headers)
                    .frame(maxHeight: 180)
                Text(Self.systemHeadersNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sentBody {
                    CodeViewerPane(document: sentBody, search: search, accessibilityLabel: "Sent body")
                }
            }
        } else {
            Text("Nothing was sent.")
                .foregroundStyle(.secondary)
        }
    }
}
