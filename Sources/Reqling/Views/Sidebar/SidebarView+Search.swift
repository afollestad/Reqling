import ReqlingKit
import SwiftUI

/// The filter field and the filter menu beside it.
struct SidebarSearchBar: View {
    @Bindable var sidebar: SidebarViewModel
    @FocusState private var isFocused: Bool
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter", text: $sidebar.query, prompt: Text("Filter projects and requests"))
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onExitCommand { sidebar.query = "" }
                    .accessibilityLabel("Filter projects and requests")
                if !sidebar.query.isEmpty {
                    Button {
                        sidebar.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Clear the filter")
                    .accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous).fill(Color.secondary.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Color(nsColor: accent) : Color.clear, lineWidth: 2)
            )
            SidebarFilterMenu(
                filter: $sidebar.filter,
                lastRunFailures: sidebar.hasLastRun ? $sidebar.showsLastRunFailures : nil
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .onChange(of: sidebar.focusRequest) { _, _ in
            isFocused = true
        }
    }
}

/// Narrows the sidebar by protocol, by HTTP method, by how each request's last run went, and, while a folder or
/// project run's report is up, to what failed in it.
private struct SidebarFilterMenu: View {
    @Binding var filter: RequestFilter
    /// `nil` while there's no folder or project run to report.
    let lastRunFailures: Binding<Bool>?

    var body: some View {
        Menu {
            Section("Protocol") {
                ForEach(RequestKind.Name.allCases, id: \.self) { name in
                    Toggle(name.title, isOn: member(name, in: \.protocols))
                }
            }
            Section("Method") {
                ForEach(RequestFilter.MethodGroup.allCases, id: \.self) { group in
                    Toggle(Self.title(for: group), isOn: member(group, in: \.methods))
                }
            }
            Section("Last Result") {
                ForEach(RunOutcomeKind.allCases, id: \.self) { outcome in
                    Toggle(Self.title(for: outcome), isOn: member(outcome, in: \.outcomes))
                }
                if let lastRunFailures {
                    Toggle("Failed in Last Run", isOn: lastRunFailures)
                }
            }
            Divider()
            Button("Clear Filters") {
                filter = .none
                lastRunFailures?.wrappedValue = false
            }
            .disabled(!isActive)
        } label: {
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(isActive ? "Filters are on" : "Filter by protocol, method, or last result")
        .accessibilityLabel("Filters")
        .accessibilityValue(isActive ? "On" : "Off")
        .iconButtonChrome(isSelected: isActive)
    }

    private var isActive: Bool {
        filter.isActive || lastRunFailures?.wrappedValue == true
    }

    private func member<Value: Hashable>(_ value: Value, in keyPath: WritableKeyPath<RequestFilter, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    filter[keyPath: keyPath].insert(value)
                } else {
                    filter[keyPath: keyPath].remove(value)
                }
            }
        )
    }

    static func title(for group: RequestFilter.MethodGroup) -> String {
        switch group {
        case .get: "GET"
        case .post: "POST"
        case .put: "PUT"
        case .patch: "PATCH"
        case .delete: "DELETE"
        case .other: "Other"
        }
    }

    static func title(for outcome: RunOutcomeKind) -> String {
        switch outcome {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .notSent: "Not Sent"
        }
    }
}
