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
                    AutoHeadersList(
                        headers: editor.autoHeaders,
                        typedHeaders: editor.spec.headers,
                        isEnabled: { !editor.spec.disabledAutoHeaders.contains($0.key) },
                        onToggle: { editor.toggleAutoHeader($0, enabled: $1) }
                    )
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

/// Per-request overrides of the defaults in Settings → Requests.
private struct RequestOptionsEditor: View {
    @Binding var options: HTTPRequestOptions
    let defaults: HTTPRequestDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow("Timeout") {
                SecondsField(
                    title: "Timeout",
                    seconds: $options.timeoutSeconds,
                    range: AppSettings.timeoutRange,
                    step: 5,
                    start: defaults.timeoutSeconds,
                    prompt: "Default (\(Int(defaults.timeoutSeconds)))"
                )
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
