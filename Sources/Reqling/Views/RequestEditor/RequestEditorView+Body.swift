import ReqlingKit
import SwiftUI

/// The body for the request's mode. Every mode keeps its own content, and a method whose body policy is none shows
/// why instead of the editor; the body is kept either way.
struct RequestBodyEditor: View {
    @Bindable var editor: RequestEditorViewModel

    var body: some View {
        if editor.spec.method.bodyPolicy.allowsBody {
            VStack(alignment: .leading, spacing: 10) {
                SectionPicker(
                    "Body type",
                    selection: $editor.spec.body.mode,
                    options: HTTPBodyMode.allCases,
                    collapsesToMenu: true,
                    label: Self.title(for:)
                )
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView {
                Label("\(editor.spec.method.rawValue) requests don't send a body", systemImage: "nosign")
            } description: {
                Text(editor.spec.body.mode == .none
                    ? "Choose another method to add a body."
                    : "The body you entered is kept and sent again if you switch to a method that allows one.")
            }
            // Fills the tab area; at its ideal width, the parent's leading alignment pins it off-center.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch editor.spec.body.mode {
        case .none:
            Text("This request has no body.")
                .foregroundStyle(.secondary)
        case .raw:
            RawBodyEditor(raw: $editor.spec.body.raw, tokenContext: editor.tokenContext)
        case .formData:
            ScrollView {
                FormDataEditor(fields: $editor.spec.body.formData, editor: editor)
            }
            .detailPaneScrollMargins()
        case .urlEncoded:
            ScrollView {
                KeyValueTable(rows: $editor.spec.body.urlEncoded, rowName: "field", tokenContext: editor.tokenContext)
            }
            .detailPaneScrollMargins()
        case .binary:
            BinaryBodyEditor(binary: $editor.spec.body.binary, editor: editor)
        case .graphQL:
            GraphQLBodyEditor(graphQL: $editor.spec.body.graphQL, tokenContext: editor.tokenContext)
        }
    }

    static func title(for mode: HTTPBodyMode) -> String {
        switch mode {
        case .none: "None"
        case .raw: "raw"
        case .formData: "form-data"
        case .urlEncoded: "x-www-form-urlencoded"
        case .binary: "binary"
        case .graphQL: "GraphQL"
        }
    }
}

private struct RawBodyEditor: View {
    @Binding var raw: RawBody
    let tokenContext: TemplateTokenContext
    @State private var isEditingCustomType = false
    @State private var editorHandle = CodeEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(RawBody.contentTypePresets, id: \.self) { type in
                        Button(type) { raw.contentType = type }
                    }
                    Divider()
                    Button("Custom…") { isEditingCustomType = true }
                } label: {
                    Text(raw.contentType.isEmpty ? "No Content-Type" : raw.contentType)
                        .font(.system(.callout, design: .monospaced))
                }
                .fixedSize()
                .help("Content-Type")
                .accessibilityLabel("Content-Type, \(raw.contentType)")
                .popover(isPresented: $isEditingCustomType) {
                    TextField("application/vnd.api+json", text: $raw.contentType)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .padding(12)
                }
                Spacer()
                if language == .json {
                    Button("Beautify") {
                        if let pretty = JSONFormatter.pretty(raw.text), !editorHandle.replaceAll(with: pretty, actionName: "Beautify") {
                            raw.text = pretty
                        }
                    }
                    .help("Re-indent the JSON, keeping its key order")
                }
            }
            CodeEditor(
                text: $raw.text,
                language: language,
                placeholder: language == .json ? #"{ "name": "{{name}}" }"# : "",
                tokenContext: tokenContext,
                accessibilityLabel: "Request body",
                handle: editorHandle
            )
            .editorChrome()
        }
    }

    private var language: SyntaxLanguage {
        ContentTypeLanguage.language(forContentType: raw.contentType)
    }
}

/// Rows are keyed by their own IDs, which `MultipartField`'s list decoding keeps unique, and write through
/// `IdentifiedRowWriter`.
private struct FormDataEditor: View {
    @Binding var fields: [MultipartField]
    let editor: RequestEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                FormDataRow(writer: IdentifiedRowWriter(rows: $fields, shown: field), editor: editor)
            }
            Button {
                fields.append(MultipartField(key: ""))
            } label: {
                Label("Add Field", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct FormDataRow: View {
    let writer: IdentifiedRowWriter<MultipartField>
    let editor: RequestEditorViewModel

    var body: some View {
        let field = writer.shown
        let tokenContext = editor.tokenContext
        HStack(spacing: 6) {
            Toggle("Send this field", isOn: writer.binding(\.isEnabled))
                .toggleStyle(.checkbox)
                .labelsHidden()
            TemplateField(text: writer.binding(\.key), placeholder: "Key", tokenContext: tokenContext, accessibilityLabel: "Field name")
                .frame(maxWidth: 200)
            Picker("Kind", selection: writer.binding(\.kind)) {
                Text("Text").tag(MultipartField.Kind.text)
                Text("File").tag(MultipartField.Kind.file)
            }
            .labelsHidden()
            .fixedSize()
            switch field.kind {
            case .text:
                TemplateField(text: writer.binding(\.value), placeholder: "Value", tokenContext: tokenContext, accessibilityLabel: "Field value")
            case .file:
                Button(editor.describe(field.file)) {
                    if let reference = editor.chooseFile() {
                        writer.edit { $0.file = reference }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Choose the file to upload")
            }
            TemplateField(
                text: Binding(
                    get: { writer.shown.contentType ?? "" },
                    set: { value in writer.edit { $0.contentType = value.isEmpty ? nil : value } }
                ),
                placeholder: "Content-Type",
                tokenContext: tokenContext,
                accessibilityLabel: "Field Content-Type"
            )
            .frame(maxWidth: 160)
            Button(action: writer.remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(IconButtonStyle())
            .help("Remove this field")
            .accessibilityLabel("Remove this field")
        }
        .opacity(field.isEnabled ? 1 : 0.55)
    }
}

private struct BinaryBodyEditor: View {
    @Binding var binary: BinaryBody
    let editor: RequestEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow("File") {
                Button(editor.describe(binary.file)) {
                    if let reference = editor.chooseFile() {
                        binary.file = reference
                    }
                }
            }
            LabeledRow("Content-Type") {
                TextField("Content-Type", text: contentType, prompt: Text("From the file extension"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var contentType: Binding<String> {
        Binding(get: { binary.contentType ?? "" }, set: { binary.contentType = $0.isEmpty ? nil : $0 })
    }
}

/// A GraphQL operation: the query and its variables, sent together as the JSON body GraphQL servers expect.
private struct GraphQLBodyEditor: View {
    @Binding var graphQL: GraphQLBody
    let tokenContext: TemplateTokenContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Operation name" would wrap in the label column; the field keeps the full name for VoiceOver.
            LabeledRow("Operation") {
                TemplateField(text: $graphQL.operationName, placeholder: "Optional", tokenContext: tokenContext, accessibilityLabel: "Operation name")
                    .frame(maxWidth: 260)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Query").font(.caption).foregroundStyle(.secondary)
                    CodeEditor(
                        text: $graphQL.query,
                        language: .graphQL,
                        placeholder: "query { viewer { login } }",
                        tokenContext: tokenContext,
                        accessibilityLabel: "GraphQL query"
                    )
                        .editorChrome()
                }
                .frame(minWidth: 200)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variables").font(.caption).foregroundStyle(.secondary)
                    CodeEditor(
                        text: $graphQL.variables,
                        language: .json,
                        placeholder: #"{ "id": "{{id}}" }"#,
                        tokenContext: tokenContext,
                        accessibilityLabel: "GraphQL variables"
                    )
                        .editorChrome()
                }
                .frame(minWidth: 160)
            }
        }
    }
}

extension View {
    /// The rounded, bordered surface code editors sit on.
    func editorChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
        return background(shape.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
            .clipShape(shape)
    }
}
