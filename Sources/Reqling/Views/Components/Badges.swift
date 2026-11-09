import ReqlingKit
import SwiftUI

/// A badge's color, or the selected-text color on an emphasized selection's highlight (increased
/// `backgroundProminence`), the color the row's own text takes there. A method or protocol tinted like the accent
/// highlight, such as PATCH's purple, would otherwise vanish into it.
struct BadgeTint: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.backgroundProminence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : color
    }
}

/// A method name in its method's color. System colors carry light and dark variants.
struct MethodBadge: View {
    let method: HTTPMethod
    var compact = false

    var body: some View {
        Text(compact ? abbreviation : method.rawValue)
            .font(.system(compact ? .caption2 : .caption, design: .monospaced).weight(.bold))
            .foregroundStyle(BadgeTint(color: Self.color(for: method)))
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
            .background(Capsule().fill(Self.color(for: statusCode)))
            .accessibilityLabel("Status \(statusCode) \(reason)")
    }

    /// Tinted by class, which the run history's compact badges share.
    static func color(for statusCode: Int) -> Color {
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
            .foregroundStyle(BadgeTint(color: Self.color))
            .lineLimit(1)
            .accessibilityLabel("gRPC")
    }
}

/// "WS" where an HTTP request shows its method. Indigo is a semantic system color, so it has light and dark variants,
/// and neither the method colors nor gRPC's teal uses it.
struct WebSocketBadge: View {
    static let color = Color.indigo

    var compact = false

    var body: some View {
        Text(compact ? "WS" : "WebSocket")
            .font(.system(compact ? .caption2 : .caption, design: .monospaced).weight(.bold))
            .foregroundStyle(BadgeTint(color: Self.color))
            .lineLimit(1)
            .accessibilityLabel("WebSocket")
    }

    /// A close code tinted by outcome, as `GRPCStatusBadge` tints a status: a normal close, a server asking to retry
    /// later (1012 Service Restart, 1013 Try Again Later), or anything else.
    static func color(forClose code: Int?) -> Color {
        switch code {
        case nil, 1000, 1001: .green
        case 1012, 1013: .orange
        default: .red
        }
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
            .background(Capsule().fill(Self.color(for: status.name)))
            .help("Status \(status.code)")
            .accessibilityLabel("Status \(status.name)")
    }

    /// Tinted by outcome, which the run history's compact badges share.
    static func color(for name: String) -> Color {
        switch name {
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
