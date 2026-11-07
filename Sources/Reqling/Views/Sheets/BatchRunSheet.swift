import ReqlingKit
import SwiftUI

/// Sets up running a folder's or project's requests in order; Run starts it and closes the sheet, once a trust
/// question the project needs has been answered over it.
struct BatchRunSheet: View {
    @State var setup: BatchRunSetupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                BatchRunSettingsSection(setup: setup)
                BatchRunRequestsSection(setup: setup)
            }
            .formStyle(.grouped)
            SheetFooter(note: setup.note, primaryTitle: "Run", isPrimaryEnabled: setup.isRunEnabled) {
                dismiss()
            } onPrimary: {
                Task {
                    _ = await setup.run()
                }
            }
        }
        .frame(width: 560, height: 620)
        .task { await setup.load() }
    }
}

private struct BatchRunSettingsSection: View {
    @Bindable var setup: BatchRunSetupModel

    var body: some View {
        Section {
            LabeledRow("Environment") {
                Picker("Environment", selection: $setup.environmentID) {
                    ForEach(setup.environments) { environment in
                        Text(environment.name).tag(EnvironmentID?.some(environment.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledRow("Iterations") {
                SectionPicker("Iterations", selection: $setup.iterations, options: BatchRunSettings.Iterations.allCases) { iterations in
                    switch iterations {
                    case .count: "Repeat"
                    case .dataFile: "Data File"
                    }
                }
            }
            switch setup.iterations {
            case .count:
                LabeledRow("Repeat") {
                    CountField(title: "Repeat", value: $setup.count, range: 1...IterationData.maximumRows, unit: setup.count == 1 ? "time" : "times")
                }
            case .dataFile:
                LabeledRow("Data File") {
                    HStack {
                        Text(setup.dataFile?.lastPathComponent ?? "None")
                            .foregroundStyle(setup.dataFile == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { Task { await setup.chooseDataFile() } }
                    }
                }
                BatchRunDataNote(data: setup.data)
            }
            LabeledRow("On Failure") {
                Toggle("Stop the run", isOn: $setup.stopsOnFailure)
                    .toggleStyle(.checkbox)
            }
            LabeledRow("Streams") {
                SecondsField(
                    title: "Stream limit",
                    seconds: $setup.streamSeconds,
                    range: 1...600,
                    step: 5,
                    start: Double(BatchRunPlan.defaultStreamSeconds),
                    prompt: "Default (\(BatchRunPlan.defaultStreamSeconds))"
                )
            }
            LabeledRowNote(text: "Event streams and WebSockets stop after this, then their post-response scripts run. "
                + "gRPC calls keep their deadline.")
        }
    }
}

/// What the chosen data file holds, or why it can't be used.
private struct BatchRunDataNote: View {
    let data: BatchRunSetupModel.DataState

    var body: some View {
        switch data {
        case .none:
            LabeledRowNote(text: "A CSV with a header row, or a JSON array of objects: one row per iteration, each column a "
                + "{{variable}}.")
        case .reading:
            LabeledRowNote(text: "Reading…")
        case .read(let rows, let columns):
            LabeledRowNote(text: "\(rows) row\(rows == 1 ? "" : "s"): \(columns.joined(separator: ", "))")
        case .failed(let message):
            LabeledRowNote(text: message)
                .foregroundStyle(.red)
        }
    }
}

/// The requests the run would run, under their folders' headers, each with a checkbox to leave it out.
private struct BatchRunRequestsSection: View {
    @Bindable var setup: BatchRunSetupModel
    @State private var range = CheckboxRange<RequestNodeID>()

    var body: some View {
        Section {
            if !setup.rows.isEmpty {
                CheckboxSelectionBar(rows: $setup.rows, isOn: \.isIncluded)
            }
            ForEach(setup.groups) { group in
                if let title = group.title {
                    // One checkbox for the folder's rows, mixed while only some run.
                    HStack(spacing: 8) {
                        Toggle(sources: rowBindings(group.rows), isOn: \.isIncluded) {
                            Text(title)
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Run every request in \(title)")
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(group.rows, id: \.self) { id in
                    if let row = setup.rows.first(where: { $0.id == id }) {
                        BatchRunRequestRow(row: row, isIndented: group.title != nil) { isOn in
                            range.click(\.isIncluded, to: isOn, at: id, in: $setup.rows)
                        }
                    }
                }
            }
        } header: {
            Text("Requests")
        }
    }

    private func rowBindings(_ ids: [RequestNodeID]) -> [Binding<BatchRunSetupModel.Row>] {
        ids.compactMap { id in
            guard let index = setup.rows.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return $setup.rows[index]
        }
    }
}

/// One request's checkbox. `Equatable` over its values; `onToggle` captures the section's range state and model,
/// which are reference storage.
private struct BatchRunRequestRow: View, Equatable {
    let row: BatchRunSetupModel.Row
    let isIndented: Bool
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Run", isOn: Binding(get: { row.isIncluded }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Run \(row.name)")
            RequestKindPill(kind: row.kind)
            Text(row.name)
                .lineLimit(1)
        }
        .padding(.leading, isIndented ? 20 : 0)
    }

    nonisolated static func == (lhs: BatchRunRequestRow, rhs: BatchRunRequestRow) -> Bool {
        lhs.row == rhs.row && lhs.isIndented == rhs.isIndented
    }
}
