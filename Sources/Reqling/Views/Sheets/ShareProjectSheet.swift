import ReqlingKit
import SwiftUI

/// Before a project is first shared: the Global variables it uses, which whoever it's shared with won't have, each
/// ticked to copy into its Default. Unticking every one shares it as it is.
struct ShareProjectSheet: View {
    let model: AppModel
    let projectID: ProjectID
    /// Where Share… was chosen, which the share sheet opens beside once this closes.
    let origin: ShareOrigin
    let offer: GlobalVariablesOffer
    @State private var copied: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, projectID: ProjectID, origin: ShareOrigin, offer: GlobalVariablesOffer) {
        self.model = model
        self.projectID = projectID
        self.origin = origin
        self.offer = offer
        _copied = State(initialValue: Set(offer.variables.map(\.key)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy Global Variables?")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("This project uses variables from Global, which isn't shared. Copy them into its Default environment "
                    + "so everyone you share it with has them. Secret values stay yours; others fill in their own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(offer.variables, id: \.key) { variable in
                            Toggle(isOn: binding(variable.key)) {
                                GlobalVariableLabel(variable: variable)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !offer.readThroughGlobals.isEmpty {
                    Label(readThroughGlobalsNote, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppMetrics.paneInset)
            SheetFooter(primaryTitle: copied.isEmpty ? "Share" : "Copy and Share") {
                dismiss()
            } onPrimary: {
                dismiss()
                if copied.isEmpty {
                    model.presentShareSheet(for: projectID, from: origin)
                } else {
                    model.copyGlobalVariablesAndShare(projectID, keys: copied, from: origin)
                }
            }
        }
        .frame(width: 460, height: 360)
    }

    /// Names scripts read through `rq.globals`, which a copy in Default can't stand in for.
    private var readThroughGlobalsNote: String {
        let names = offer.readThroughGlobals.map { "“\($0)”" }.joined(separator: ", ")
        let pronoun = offer.readThroughGlobals.count == 1 ? "it" : "them"
        return "Scripts read \(names) straight from Global, so everyone needs \(pronoun) in their own Global."
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { copied.contains(key) },
            set: { isOn in
                if isOn {
                    copied.insert(key)
                } else {
                    copied.remove(key)
                }
            }
        )
    }
}

private struct GlobalVariableLabel: View {
    let variable: Variable

    var body: some View {
        HStack(spacing: 6) {
            Text(variable.key)
                .font(.system(.body, design: .monospaced))
            if variable.isSecret {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Secret: copied with your value, which stays yours")
                    .accessibilityLabel("Secret")
            }
        }
    }
}
