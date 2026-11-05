import ReqlingKit
import SwiftUI

/// Every type by kind, or what the filter finds; choosing one opens it.
struct GraphQLTypeList: View {
    let sections: [GraphQLSchemaBrowserModel.Section]
    let browser: GraphQLSchemaBrowserModel

    var body: some View {
        if sections.isEmpty {
            CompactEmptyState(systemImage: "magnifyingglass", title: "No Matches", message: "No type or field has that name.") {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                GraphQLTypeListRow(entry: entry) {
                                    browser.show(entry.type)
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
        }
    }
}

/// One type or field. `Equatable` over its entry; `open` captures only the browser, a reference already compared by
/// the parent.
private struct GraphQLTypeListRow: View, Equatable {
    let entry: GraphQLSchemaBrowserModel.Entry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.field.map { "\(entry.type).\($0)" } ?? entry.type)
                    .font(.system(.body, design: .monospaced))
                    .strikethrough(entry.isDeprecated)
                    .lineLimit(1)
                if let summary = entry.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.field == nil ? "Shows this type" : "Shows the type with this field")
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry
    }
}
