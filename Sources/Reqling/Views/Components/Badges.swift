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
