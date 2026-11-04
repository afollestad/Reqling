import ReqlingKit
import SwiftUI

/// Edits an `HTTPAuth`, shared by requests, folders, and projects. A project has nothing to inherit from, so it hides
/// the Inherit choice.
struct AuthEditor: View {
    @Binding var auth: HTTPAuth
    var allowsInherit = true
    /// Explains what Inherit resolves to here, such as "Bearer token from “Users”".
    var inheritedDescription: String?
    var tokenContext: TemplateTokenContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledRow("Type") {
                Picker("Type", selection: kind) {
                    ForEach(kinds, id: \.self) { kind in
                        Text(Self.title(for: kind)).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            fields
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fields: some View {
        switch auth {
        case .inherit:
            LabeledRowNote(text: inheritedDescription ?? "Uses the auth of the enclosing folder or project.")
        case .none:
            LabeledRowNote(text: "No credentials are added to the request.")
        case .basic(let username, let password):
            field("Username", value(username) { .basic(username: $0, password: password) })
            field("Password", value(password) { .basic(username: username, password: $0) })
            secretHint
        case .bearer(let token):
            field("Token", value(token) { .bearer(token: $0) }, placeholder: "{{token}}")
            secretHint
        case .apiKey(let name, let keyValue, let location):
            field("Key", value(name) { .apiKey(name: $0, value: keyValue, location: location) }, placeholder: "X-API-Key")
            field("Value", value(keyValue) { .apiKey(name: name, value: $0, location: location) })
            LabeledRow("Add to") {
                SectionPicker(
                    "Add to",
                    selection: Binding(get: { location }, set: { auth = .apiKey(name: name, value: keyValue, location: $0) }),
                    options: HTTPAuth.APIKeyLocation.allCases,
                    label: Self.locationTitle(for:)
                )
            }
            secretHint
        }
    }

    private var secretHint: some View {
        LabeledRowNote(text: "Credentials are saved in the project as typed. Use a secret variable, such as {{token}}, to keep them in the Keychain.")
            .font(.caption)
    }

    private func field(_ title: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        LabeledRow(title) {
            TemplateField(text: text, placeholder: placeholder, tokenContext: tokenContext, accessibilityLabel: title)
        }
    }

    private var kinds: [HTTPAuth.Kind] {
        allowsInherit ? HTTPAuth.Kind.allCases : HTTPAuth.Kind.allCases.filter { $0 != .inherit }
    }

    private var kind: Binding<HTTPAuth.Kind> {
        Binding(
            get: { auth.kind },
            set: { kind in
                guard kind != auth.kind else {
                    return
                }
                switch kind {
                case .inherit: auth = .inherit
                case .none: auth = .none
                case .basic: auth = .basic(username: "", password: "")
                case .bearer: auth = .bearer(token: "")
                case .apiKey: auth = .apiKey(name: "", value: "", location: .header)
                }
            }
        )
    }

    private func value(_ current: String, _ make: @escaping (String) -> HTTPAuth) -> Binding<String> {
        Binding(get: { current }, set: { auth = make($0) })
    }

    static func locationTitle(for location: HTTPAuth.APIKeyLocation) -> String {
        switch location {
        case .header: "Header"
        case .query: "Query parameter"
        }
    }

    static func title(for kind: HTTPAuth.Kind) -> String {
        switch kind {
        case .inherit: "Inherit"
        case .none: "No Auth"
        case .basic: "Basic"
        case .bearer: "Bearer Token"
        case .apiKey: "API Key"
        }
    }
}
