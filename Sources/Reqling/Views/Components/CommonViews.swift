import SwiftUI

/// A sheet's bottom bar: an optional note, then Cancel and the primary action, bound to Escape and Return.
struct SheetFooter: View {
    var note: String?
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
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPrimaryEnabled)
            }
            .padding(12)
        }
    }
}

/// Switches between sections of one surface (tabs, body modes, response formats). It hugs its options: given a wider
/// frame, macOS centers a segmented control and pulls it off the pane's leading edge. macOS also sizes every segment
/// to the widest label, so where that does not fit (the six body modes in a default-width window) it becomes a menu
/// rather than clipping or truncating segments.
struct SectionPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.segmented)
                .fixedSize()
            picker
                .pickerStyle(.menu)
                .fixedSize()
        }
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

/// The title block of a full detail screen.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                }
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
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    actions
                }
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
