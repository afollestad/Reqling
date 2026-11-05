import ReqlingKit
import SwiftUI

/// The schema beside a GraphQL request, in the inspector: its types by kind, or what a filter finds, and any type in
/// detail, with its fields, arguments, and the types they name a click away.
///
/// The filter is a field in the pane rather than `.searchable`, and navigation is the browser model's own path rather
/// than a `NavigationStack`: both of those would put controls in the window's toolbar.
struct GraphQLSchemaBrowser: View {
    let editor: RequestEditorViewModel
    let model: GraphQLEditorModel

    var body: some View {
        let browser = model.browser
        let snapshot = model.schema.snapshot
        VStack(spacing: 0) {
            GraphQLSchemaBrowserHeader(browser: browser)
            Divider()
            if let snapshot {
                if browser.filter.isEmpty, let name = browser.currentType, let type = snapshot.typeSystem.type(named: name) {
                    GraphQLTypeDetail(type: type, typeSystem: snapshot.typeSystem, browser: browser)
                        .id(type.name)
                } else {
                    GraphQLTypeList(sections: browser.sections(in: snapshot), browser: browser)
                }
            } else {
                CompactEmptyState(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "No Schema",
                    message: Self.reason(model.schema.status)
                ) {
                    HStack(spacing: 8) {
                        Button("Reload") { editor.refreshGraphQLSchema() }
                        Button("Choose File…") { editor.chooseGraphQLSchemaFile() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static func reason(_ status: GraphQLSchemaLoader.Status) -> String {
        switch status {
        case .loading: "Loading the schema…"
        case .idle(let message), .failed(let message): message
        case .ready: "The schema has no types."
        }
    }
}

/// The back button, once a type is open, and the filter.
private struct GraphQLSchemaBrowserHeader: View {
    @Bindable var browser: GraphQLSchemaBrowserModel

    var body: some View {
        HStack(spacing: 6) {
            if !browser.path.isEmpty, browser.filter.isEmpty {
                Button {
                    browser.back()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .help("Back")
                .accessibilityLabel("Back")
            }
            TextField("Filter types and fields", text: $browser.filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter the schema")
        }
        .padding(10)
    }
}

/// A type's name, styled as a link that opens it.
struct GraphQLTypeLink: View {
    let text: String
    let type: String
    let browser: GraphQLSchemaBrowserModel
    @Environment(\.appAccent) private var accent

    var body: some View {
        Button(text) {
            browser.show(type)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: accent))
        .accessibilityAddTraits(.isLink)
        .help("Show \(type)")
    }
}
