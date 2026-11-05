import ReqlingKit
import SwiftUI

/// One run: how it ended and when, then how long it took, how much came back, and against which environment.
struct RunHistoryRow: View, Equatable {
    let run: RunSummary
    let time: String
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RunStatusBadge(status: run.status)
                Text(time)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if isLatest {
                    Text("Latest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let duration = run.duration {
                    Text(ResponseStatusBar.duration(duration))
                }
                if let bytes = run.responseByteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
                if let environment = run.environmentName {
                    Label(environment, systemImage: "square.stack.3d.up")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A run's outcome as a small capsule: its HTTP status code, its gRPC status name, or why it never got a response.
struct RunStatusBadge: View {
    let status: RunSummary.Status

    var body: some View {
        Text(title)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .accessibilityLabel(accessibilityTitle)
    }

    private var title: String {
        switch status {
        case .http(let code): "\(code)"
        case .grpc(_, let name): name ?? "NO STATUS"
        case .failure(let kind): Self.title(for: kind)
        }
    }

    private var accessibilityTitle: String {
        switch status {
        case .http(let code): "Status \(code)"
        case .grpc(_, let name): "Status \(name ?? "unknown")"
        case .failure(let kind): Self.title(for: kind)
        }
    }

    private var color: Color {
        switch status {
        case .http(let code): StatusBadge.color(for: code)
        case .grpc(_, let name): GRPCStatusBadge.color(for: name ?? "")
        case .failure(.cancelled): .gray
        case .failure: .red
        }
    }

    private static func title(for kind: RunFailure.Kind) -> String {
        switch kind {
        case .invalidRequest: "Not Sent"
        case .tls: "TLS Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed Out"
        case .transport: "Failed"
        }
    }
}
