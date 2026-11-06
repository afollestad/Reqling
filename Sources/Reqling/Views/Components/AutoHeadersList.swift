import ReqlingKit
import SwiftUI

/// The headers Reqling adds to a request itself, for the HTTP and WebSocket editors' Headers tabs. A typed header with
/// the same name replaces one, unless `ignoresTyped` says the connection writes it regardless; the switchable ones can
/// be turned off, or for one off by default (a WebSocket's `Origin`), on.
struct AutoHeadersList: View {
    let headers: [AutoHeader]
    let typedHeaders: [KeyValuePair]
    let isEnabled: (AutoHeader) -> Bool
    let onToggle: @MainActor (AutoHeader, Bool) -> Void
    /// A fixed header a typed copy of is dropped rather than sent (a WebSocket's `Host`, `Upgrade`, and so on).
    var ignoresTyped: (AutoHeader) -> Bool = { _ in false }
    /// Who sets the fixed ones, for their tooltip.
    var fixedSetter = "the URL loading system"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automatic headers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(headers, id: \.key) { header in
                AutoHeaderRow(
                    header: header,
                    typed: typedState(header),
                    isEnabled: isEnabled(header),
                    fixedSetter: fixedSetter,
                    onToggle: { onToggle(header, $0) }
                )
            }
        }
    }

    private func typedState(_ header: AutoHeader) -> AutoHeaderRow.Typed {
        guard typedHeaders.contains(where: { $0.isEnabled && $0.key.lowercased() == header.key }) else {
            return .none
        }
        return ignoresTyped(header) ? .ignored : .replacing
    }
}

private struct AutoHeaderRow: View {
    /// What a typed header of the same name does to this one.
    enum Typed {
        case none
        case replacing
        case ignored
    }

    let header: AutoHeader
    let typed: Typed
    let isEnabled: Bool
    let fixedSetter: String
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Send \(header.name)", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!header.isOverridable || typed == .replacing)
            Text(header.name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 160, alignment: .leading)
            Text(detail)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(typed == .replacing || !isEnabled ? 0.5 : 0.85)
        .help(header.isOverridable ? "Added automatically; add a header with the same name to replace it." : "Set by \(fixedSetter).")
    }

    /// Turning a header off only stops Reqling setting it; where macOS fills in its own, the row says so. One that is off
    /// still shows its value, dimmed, so turning it on holds no surprise.
    private var detail: String {
        switch typed {
        case .replacing:
            return "Replaced by your header"
        case .ignored:
            return "\(header.value); yours isn't sent"
        case .none:
            if !isEnabled, let fallback = header.systemFallback {
                return "Off; macOS sends \(fallback) instead"
            }
            return header.value
        }
    }
}
