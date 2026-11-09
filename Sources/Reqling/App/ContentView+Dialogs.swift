import ReqlingKit
import SwiftUI

/// Asks before a project, folder, or request moves to the Trash; see `AppModel.requestTrash(_:)`.
struct TrashConfirmationDialog: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.trashPending?.title ?? "",
            isPresented: Binding(get: { model.trashPending != nil }, set: { if !$0 { model.trashPending = nil } }),
            titleVisibility: .visible,
            // The action takes the item from here, not the model: dismissal may clear `trashPending` first.
            presenting: model.trashPending
        ) { confirmation in
            Button("Move to Trash", role: .destructive) { model.trash(confirmation) }
        } message: { confirmation in
            Text(confirmation.consequences)
        }
    }
}

/// Asks before a folder or request moves into another project; see `AppModel.requestMove(_:from:to:into:at:)`.
struct MoveConfirmationDialog: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.movePending?.title ?? "",
            isPresented: Binding(get: { model.movePending != nil }, set: { if !$0 { model.movePending = nil } }),
            titleVisibility: .visible,
            // The action takes the move from here, not the model: dismissal may clear `movePending` first.
            presenting: model.movePending
        ) { confirmation in
            Button("Move") { model.move(confirmation) }
        } message: { confirmation in
            Text(confirmation.consequences)
        }
    }
}

/// Asks whether a project's scripts may run on this Mac; see `AppModel.decideScriptTrust`. Don't Run is remembered, as
/// Trust is; closing the alert some other way decides nothing. Presented over an open sheet, as `AlertPresenter` is, so
/// a folder or project run started from its sheet asks there.
struct ScriptTrustAlert: ViewModifier {
    let model: AppModel
    let isInSheet: Bool

    func body(content: Content) -> some View {
        content.alert(
            model.scriptTrustPending?.title ?? "",
            isPresented: isPresented,
            presenting: model.scriptTrustPending
        ) { _ in
            Button("Trust Scripts") { model.answerScriptTrust(true) }
            Button("Don't Run", role: .cancel) { model.answerScriptTrust(false) }
        } message: { request in
            Text(request.message)
        }
    }

    /// Closing the alert without a button, which a button's own answer already did, leaves the question undecided.
    private var isPresented: Binding<Bool> {
        Binding(get: { model.scriptTrustPending != nil && (model.sheet != nil) == isInSheet }, set: { isShown in
            if !isShown, model.scriptTrustPending != nil {
                model.answerScriptTrust(nil)
            }
        })
    }
}

/// Says what syncs as an iCloud account first syncs on this Mac, since sync is on by default and uploads what's here.
struct FirstSyncNotice: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            "Reqling Syncs with iCloud",
            isPresented: Binding(get: { model.iCloud.showsFirstSyncNotice }, set: { model.iCloud.showsFirstSyncNotice = $0 })
        ) {
            Button("OK") {}
            Button("Open Settings") { model.showSettings(.iCloud) }
        } message: {
            Text("Projects in Reqling's own folder, Global, and current values sync with your other Macs signed in to this "
                + "iCloud account, end-to-end encrypted. A copy of everything from before is kept, and Settings ▸ iCloud "
                + "shows it or turns sync off.")
        }
    }
}

/// Asks before run history is cleared; it lives only on this Mac, so nothing can bring it back.
struct HistoryClearConfirmation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.historyClearPending?.title ?? "",
            isPresented: Binding(get: { model.historyClearPending != nil }, set: { if !$0 { model.historyClearPending = nil } }),
            titleVisibility: .visible,
            // The action takes the scope from here: dismissal may clear `historyClearPending` first.
            presenting: model.historyClearPending
        ) { scope in
            Button("Clear History", role: .destructive) { model.clearHistory(scope) }
        } message: { _ in
            Text("Past runs and their responses are deleted from this Mac. This can't be undone.")
        }
    }
}
