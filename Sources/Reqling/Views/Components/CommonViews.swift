import SwiftUI

/// A sheet's bottom bar: an optional note, then Cancel and the primary action, bound to Escape and Return.
struct SheetFooter: View {
    var note: String?
    /// `nil` leaves only the primary action, for a sheet whose work is done and has nothing left to cancel.
    var cancelTitle: String? = "Cancel"
    var primaryTitle = "Done"
    var isPrimaryEnabled = true
    let onCancel: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let cancelTitle {
                    Button(cancelTitle, role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPrimaryEnabled)
            }
            .padding(12)
        }
    }
}

/// Switches between sections of one surface (tabs, body modes, response formats). It hugs its options: given a wider
/// frame, macOS centers a segmented control and pulls it off the pane's leading edge.
///
/// macOS sizes every segment to the widest label, so a picker that can outgrow its row (the six body modes in a
/// default-width window) sets `collapsesToMenu`. It then fills its row, with the segments at the leading edge, and
/// becomes a menu rather than clipping or truncating segments when the row is too narrow; see `WidthAdaptive` for why
/// that is not `ViewThatFits`.
struct SectionPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let collapsesToMenu: Bool
    let label: (Value) -> String

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        collapsesToMenu: Bool = false,
        label: @escaping (Value) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.collapsesToMenu = collapsesToMenu
        self.label = label
    }

    var body: some View {
        if collapsesToMenu {
            WidthAdaptive {
                segmented
            } fallback: {
                picker
                    .pickerStyle(.menu)
                    .fixedSize()
            }
        } else {
            segmented
        }
    }

    private var segmented: some View {
        picker
            .pickerStyle(.segmented)
            .fixedSize()
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
    }
}

/// The title block of a Settings page; other detail screens are named by the window's `DetailTitleBar`.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// An empty state for a narrow column, where `ContentUnavailableView`'s layout would clip.
struct CompactEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    private let actions: Actions

    init(systemImage: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Side by side when the column allows, stacked near the sidebar's minimum width.
            WidthAdaptive(alignment: .center) {
                HStack(spacing: 6) {
                    actions
                }
            } fallback: {
                VStack(spacing: 6) {
                    actions
                }
            }
            .controlSize(.small)
        }
        .padding(AppMetrics.paneInset)
        // Wide enough that a one-sentence message wraps to two lines in the sidebar's default width.
        .frame(maxWidth: 300)
    }
}

extension View {
    /// For a scroll view in a detail pane: its content ends at the pane's inset, flush with the controls above it, and
    /// the scroller runs in the pane's margin beyond that instead of over the rows' trailing buttons.
    func detailPaneScrollMargins() -> some View {
        contentMargins(.trailing, AppMetrics.detailPaneInset, for: .scrollContent)
            .padding(.trailing, -AppMetrics.detailPaneInset)
    }
}
