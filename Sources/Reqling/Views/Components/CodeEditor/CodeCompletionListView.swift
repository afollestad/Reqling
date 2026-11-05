import SwiftUI

/// The open completion list, which the text view updates as the user types and moves; its panel shows it without
/// being rebuilt per keystroke.
@MainActor
@Observable
final class CodeCompletionModel {
    var items: [CodeCompletionItem] = []
    var highlighted = 0
    /// A click on a row; the text view inserts the item.
    @ObservationIgnored var onAccept: ((CodeCompletionItem) -> Void)?

    static let visibleRows = 9
    static let rowHeight: CGFloat = 22
    static let width: CGFloat = 380

    var highlightedItem: CodeCompletionItem? {
        items.indices.contains(highlighted) ? items[highlighted] : nil
    }

    /// Moves the highlight, stopping at either end.
    func move(by offset: Int) {
        guard !items.isEmpty else {
            return
        }
        highlighted = min(max(0, highlighted + offset), items.count - 1)
    }
}

/// Suggestions with their kind, name, and type, and the highlighted one's description beneath.
struct CodeCompletionListView: View {
    let model: CodeCompletionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            CodeCompletionRow(item: item, isHighlighted: item.id == model.highlighted)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onAccept?(item) }
                        }
                    }
                }
                .frame(height: CGFloat(min(model.items.count, CodeCompletionModel.visibleRows)) * CodeCompletionModel.rowHeight)
                .onChange(of: model.highlighted) { _, highlighted in
                    proxy.scrollTo(highlighted)
                }
            }
            if let summary = model.highlightedItem?.summary {
                Divider()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: CodeCompletionModel.width)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

/// One suggestion. `Equatable` over its values; it holds no closures.
struct CodeCompletionRow: View, Equatable {
    let item: CodeCompletionItem
    let isHighlighted: Bool
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Text(item.kind.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(item.kind.tint)
                .frame(width: 16, height: 16)
                .background(item.kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius))
                .accessibilityHidden(true)
            Text(item.label)
                .font(.system(.body, design: .monospaced))
                .strikethrough(item.isDeprecated)
                .foregroundStyle(item.isDeprecated ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CodeCompletionModel.rowHeight)
        .background(isHighlighted ? Color(nsColor: accent).opacity(0.22) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// Compares the values only: the accent comes from the environment.
    nonisolated static func == (lhs: CodeCompletionRow, rhs: CodeCompletionRow) -> Bool {
        lhs.item == rhs.item && lhs.isHighlighted == rhs.isHighlighted
    }
}

/// What the hover card shows: the name under the pointer, the problems there, or both.
struct CodeHoverCardContent: Equatable {
    let hover: CodeHoverContent?
    let diagnostics: [CodeDiagnostic]
}

/// The signature, description, and deprecation of the name under the pointer, and any problem marked there.
struct CodeHoverCard: View {
    static let maxWidth: CGFloat = 420

    let content: CodeHoverCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(content.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label {
                    Text(diagnostic.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: CodeTextView.underlineColor(diagnostic.severity)))
                }
                .font(.callout)
            }
            if let hover = content.hover {
                if !content.diagnostics.isEmpty {
                    Divider()
                }
                Text(hover.signature)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = hover.deprecationReason {
                    Text("Deprecated: \(reason)")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = hover.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
