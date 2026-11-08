import ReqlingKit
import ReqlingScriptProtocol
import SwiftUI

/// A run's scripts: each script's tests and error, notes on scripts that didn't run, then the console. With a console,
/// the results take only the height they need, up to `resultsLimit`, and the console fills the rest.
struct ScriptReportView: View {
    static let resultsLimit: CGFloat = 240

    let scripts: ScriptReportPresentation
    @State private var search = BodySearchModel()
    @State private var resultsHeight: CGFloat = 0

    var body: some View {
        let hasResults = !scripts.groups.isEmpty || !scripts.notes.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            if hasResults {
                ScrollView {
                    ScriptResultsList(scripts: scripts)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
                }
                .frame(height: scripts.console == nil ? nil : min(resultsHeight, Self.resultsLimit))
            }
            if let console = scripts.console {
                Text("Console")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                CodeViewerPane(document: console, search: search, accessibilityLabel: "Console")
            } else if !hasResults {
                Text("The scripts ran no tests and printed nothing.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScriptResultsList: View {
    let scripts: ScriptReportPresentation

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(scripts.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(scripts.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    if let error = group.error {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            if let detail = group.errorDetail {
                                Text(detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(group.tests) { test in
                        ScriptTestRow(test: test)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScriptTestRow: View {
    let test: ScriptReportPresentation.Test

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(test.name)
                    .textSelection(.enabled)
                if let tally = test.tally {
                    Text(tally)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let message = test.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(test.result.rawValue)
    }

    private var icon: String {
        switch test.result {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch test.result {
        case .passed: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }
}

/// The run's tests in a status bar, green when every one that ran passed and nothing threw, red otherwise. A run that
/// got a response but whose scripts failed without a test says so instead; a run with none already reads Failed.
struct ResponseTestsMetric: View {
    let scripts: ScriptReportPresentation
    let gotResponse: Bool

    var body: some View {
        let ran = scripts.counts.passed + scripts.counts.failed
        if ran > 0 {
            HStack(spacing: 4) {
                Text("Tests")
                    .foregroundStyle(.secondary)
                Text("\(scripts.counts.passed)/\(ran)")
                    .monospacedDigit()
                    .foregroundStyle(scripts.hasFailures ? .red : .green)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tests, \(scripts.counts.passed) of \(ran) passed")
        } else if scripts.hasFailures, gotResponse {
            Label("Script Error", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// Says a run went without its scripts because the project isn't trusted on this Mac, with a way to trust it for the
/// next run. Gone once the project is trusted.
struct ScriptsOffNotice: View {
    let projectID: ProjectID
    let model: AppModel

    var body: some View {
        if model.scriptTrust(for: projectID) != .trusted {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("This run went without its scripts: they're off for this project on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Trust Scripts") { model.setScriptTrust(.trusted, for: projectID) }
                    .help("Run this project's scripts from the next run on")
            }
            .font(.callout)
            .padding(.horizontal, AppMetrics.detailPaneInset)
            .padding(.vertical, 6)
        }
    }
}
