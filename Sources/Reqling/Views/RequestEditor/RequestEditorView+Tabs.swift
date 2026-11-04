import ReqlingKit
import SwiftUI

struct RequestEditorTabContent: View {
    @Bindable var editor: RequestEditorViewModel
    let model: AppModel

    var body: some View {
        switch editor.tab {
        case .params:
            ScrollView {
                KeyValueTable(rows: $editor.spec.queryParameters, rowName: "parameter", tokenContext: editor.tokenContext)
            }
            .detailPaneScrollMargins()
        case .headers:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    KeyValueTable(rows: $editor.spec.headers, keyPlaceholder: "Header", rowName: "header", tokenContext: editor.tokenContext)
                    AutoHeadersList(editor: editor)
                }
            }
            .detailPaneScrollMargins()
        case .body:
            RequestBodyEditor(editor: editor)
        case .auth:
            ScrollView {
                AuthEditor(
                    auth: $editor.spec.auth,
                    inheritedDescription: AuthEditor.inheritedDescription(for: editor.requestID, in: editor.projectID, model: model),
                    tokenContext: editor.tokenContext
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .options:
            RequestOptionsEditor(options: $editor.spec.options, defaults: model.settings.settings.requestDefaults)
        }
    }
}

/// The headers Reqling adds itself. A user header with the same name replaces one, and overridable ones can be off.
private struct AutoHeadersList: View {
    let editor: RequestEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automatic headers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(editor.autoHeaders, id: \.key) { header in
                AutoHeaderRow(
                    header: header,
                    isOverridden: isOverridden(header),
                    isEnabled: !editor.spec.disabledAutoHeaders.contains(header.key),
                    onToggle: { editor.toggleAutoHeader(header, enabled: $0) }
                )
            }
        }
    }

    private func isOverridden(_ header: AutoHeader) -> Bool {
        editor.spec.headers.contains { $0.isEnabled && $0.key.lowercased() == header.key }
    }
}

private struct AutoHeaderRow: View {
    let header: AutoHeader
    let isOverridden: Bool
    let isEnabled: Bool
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Send \(header.name)", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!header.isOverridable || isOverridden)
            Text(header.name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 160, alignment: .leading)
            Text(detail)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(isOverridden || !isEnabled ? 0.5 : 0.85)
        .help(header.isOverridable ? "Added automatically; add a header with the same name to replace it." : "Set by the URL loading system.")
    }

    /// Turning a header off only stops Reqling setting it; where macOS fills in its own, the row says so.
    private var detail: String {
        if isOverridden {
            return "Replaced by your header"
        }
        if !isEnabled, let fallback = header.systemFallback {
            return "Off; macOS sends \(fallback) instead"
        }
        return header.value
    }
}

/// Per-request overrides of the defaults in Settings → Requests.
private struct RequestOptionsEditor: View {
    @Binding var options: HTTPRequestOptions
    let defaults: HTTPRequestDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow("Timeout") {
                TextField("Timeout", value: $options.timeoutSeconds, format: .number, prompt: Text("Default (\(Int(defaults.timeoutSeconds)) s)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 160)
            }
            LabeledRow("Redirects") {
                choice("Follow redirects", $options.followRedirects, default: defaults.followRedirects, onTitle: "Follow", offTitle: "Don't follow")
            }
            LabeledRow("TLS") {
                choice("Verify TLS certificates", $options.verifyTLS, default: defaults.verifyTLS, onTitle: "Verify", offTitle: "Don't verify")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func choice(_ title: String, _ value: Binding<Bool?>, default isOn: Bool, onTitle: String, offTitle: String) -> some View {
        Picker(title, selection: value) {
            Text("Default (\(isOn ? onTitle : offTitle))").tag(Bool?.none)
            Text(onTitle).tag(Bool?.some(true))
            Text(offTitle).tag(Bool?.some(false))
        }
        .labelsHidden()
        .fixedSize()
    }
}
