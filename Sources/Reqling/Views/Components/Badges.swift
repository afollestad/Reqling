import ReqlingKit
import SwiftUI

/// A method name in its method's color. System colors carry light and dark variants.
struct MethodBadge: View {
    let method: HTTPMethod
    var compact = false

    var body: some View {
        Text(compact ? abbreviation : method.rawValue)
            .font(.system(compact ? .caption2 : .caption, design: .monospaced).weight(.bold))
            .foregroundStyle(Self.color(for: method))
            .lineLimit(1)
            .accessibilityLabel(method.rawValue)
    }

    private var abbreviation: String {
        switch method {
        case .delete: "DEL"
        case .options: "OPT"
        case .patch: "PTCH"
        default: String(method.rawValue.prefix(4))
        }
    }

    static func color(for method: HTTPMethod) -> Color {
        switch method {
        case .get: .green
        case .post: .orange
        case .put: .blue
        case .patch: .purple
        case .delete: .red
        default: .secondary
        }
    }
}

/// An HTTP status code tinted by class.
struct StatusBadge: View {
    let statusCode: Int
    let reason: String

    var body: some View {
        Text("\(statusCode) \(reason)")
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
            .accessibilityLabel("Status \(statusCode) \(reason)")
    }

    private var color: Color {
        switch statusCode {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }
}

/// "gRPC" where an HTTP request shows its method. Teal is a semantic system color, so it has light and dark variants,
/// and none of the method colors uses it.
struct GRPCBadge: View {
    static let color = Color.teal

    var compact = false

    var body: some View {
        Text("gRPC")
            .font(.system(compact ? .caption2 : .caption, design: .monospaced).weight(.bold))
            .foregroundStyle(Self.color)
            .lineLimit(1)
            .accessibilityLabel("gRPC")
    }
}

/// A gRPC status by its canonical name, tinted by outcome: OK, a retryable condition, or an error.
struct GRPCStatusBadge: View {
    let status: GRPCStatusRecord

    var body: some View {
        Text(status.name)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
            .help("Status \(status.code)")
            .accessibilityLabel("Status \(status.name)")
    }

    private var color: Color {
        switch status.name {
        case "OK": .green
        case "CANCELLED": .gray
        case "DEADLINE_EXCEEDED", "UNAVAILABLE", "RESOURCE_EXHAUSTED", "ABORTED": .orange
        default: .red
        }
    }
}

/// Whether each side of a gRPC call streams, as its method's descriptor says.
struct GRPCMethodKindBadge: View {
    let kind: GRPCMethodKind

    var body: some View {
        Text(Self.title(for: kind))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
            .fixedSize()
            .accessibilityLabel("Call type, \(Self.title(for: kind))")
    }

    static func title(for kind: GRPCMethodKind) -> String {
        switch kind {
        case .unary: "Unary"
        case .clientStreaming: "Client streaming"
        case .serverStreaming: "Server streaming"
        case .bidirectionalStreaming: "Bidirectional streaming"
        }
    }
}
