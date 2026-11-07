import Foundation
import ReqlingKit
import SwiftUI

/// What the run sheet remembers for a folder or project until Reqling quits, saved when a run starts.
struct BatchRunSettings: Equatable {
    enum Iterations: Hashable, CaseIterable {
        case count
        case dataFile
    }

    /// `nil` takes the project's active environment.
    var environmentID: EnvironmentID?
    var iterations = Iterations.count
    var count = 1
    var dataFile: URL?
    var stopsOnFailure = false
    /// `nil` takes `BatchRunPlan.defaultStreamSeconds`.
    var streamSeconds: Double?
    /// Requests left out, rather than those kept, so one added since runs unless it's unchecked too.
    var excluded: Set<RequestNodeID> = []
}

/// Running a folder's or project's requests: what the sheet, the sidebar, the detail screens, and the Request menu
/// start, stop, and dismiss. `BatchRunner` does the running; agents start theirs through MCP, and the sidebar shows
/// either.
extension AppModel {
    /// What a run command acts on: the selected folder or project, or a selected request's folder (or its project, at
    /// the top level).
    func batchTarget(for selection: SidebarItem?) -> BatchRunScope? {
        guard let selection, let document = library.document(selection.projectID) else {
            return nil
        }
        guard let node = selection.nodeID else {
            return BatchRunScope(projectID: selection.projectID, folderID: nil)
        }
        if document.folder(node) != nil {
            return BatchRunScope(projectID: selection.projectID, folderID: node)
        }
        guard document.request(node) != nil else {
            return nil
        }
        return BatchRunScope(projectID: selection.projectID, folderID: document.parentID(of: node))
    }

    func batchRunTitle(for scope: BatchRunScope?) -> String {
        scope?.folderID == nil ? "Run Project…" : "Run Folder…"
    }

    /// Whether `scope` holds a request to run while no other run is going.
    func canRunBatch(_ scope: BatchRunScope?) -> Bool {
        guard let scope, !batches.isRunning, let document = library.document(scope.projectID) else {
            return false
        }
        return !document.requests(inFolder: scope.folderID).isEmpty
    }

    /// Opens the run sheet for `scope`.
    func openBatchRun(_ scope: BatchRunScope?) {
        guard let scope, canRunBatch(scope) else {
            return
        }
        sheet = .batchRun(scope)
    }

    /// The sheet's settings for `scope`: the last ones it ran with, its environment dropped once that's gone.
    func batchRunSettings(for scope: BatchRunScope) -> BatchRunSettings {
        var settings = batchRunSettings[scope] ?? BatchRunSettings()
        if let environment = settings.environmentID, library.document(scope.projectID)?.environment(environment) == nil {
            settings.environmentID = nil
        }
        return settings
    }

    /// Starts a run of `scope` from the sheet's settings, saving pending edits first so the run sends what the window
    /// shows. A project whose scripts aren't decided yet asks first, over the sheet. Returns whether the run started,
    /// which closes the sheet; a dismissed question, or data that can't be read, leaves it open.
    func beginBatchRun(_ scope: BatchRunScope, settings: BatchRunSettings) async -> Bool {
        flushPendingEdits()
        guard let document = library.document(scope.projectID) else {
            return false
        }
        var plan = BatchRunPlan(
            scope: scope,
            environmentID: settings.environmentID,
            requests: document.requests(inFolder: scope.folderID).map(\.id).filter { !settings.excluded.contains($0) },
            iterations: .count(settings.count),
            stopsOnFailure: settings.stopsOnFailure,
            streamLimit: StreamLimit(maxDuration: .seconds(settings.streamSeconds ?? Double(BatchRunPlan.defaultStreamSeconds)))
        )
        if settings.iterations == .dataFile, let file = settings.dataFile {
            do throws(IterationDataError) {
                plan.iterations = .data(source: .file(file), rows: try await IterationData.read(file))
            } catch {
                alert = AppAlert(title: "The Data File Can't Be Used", message: error.message)
                return false
            }
        }
        sidebar.showsLastRunFailures = false
        do throws(BatchRunRefusal) {
            let handle = try await batches.begin(plan, mayPromptForTrust: true)
            batchRunSettings[scope] = settings
            if sheet == .batchRun(scope) {
                sheet = nil
            }
            announceWhenFinished(handle)
            return true
        } catch {
            if error != .trustDismissed {
                alert = AppAlert(title: "The Run Didn't Start", message: error.localizedDescription)
            }
            return false
        }
    }

    /// Runs the last run's plan again, as the person's: an agent's included.
    func rerunBatch() async {
        flushPendingEdits()
        sidebar.showsLastRunFailures = false
        do throws(BatchRunRefusal) {
            announceWhenFinished(try await batches.rerun())
        } catch {
            if error != .trustDismissed {
                alert = AppAlert(title: "The Run Didn't Start", message: error.localizedDescription)
            }
        }
    }

    func stopBatchRun() {
        batches.stop()
    }

    func dismissBatchRun() {
        batches.dismiss()
        sidebar.showsLastRunFailures = false
    }

    /// Tells VoiceOver how the run went once it ends, since the sidebar's bar changes without taking focus.
    private func announceWhenFinished(_ handle: BatchRunHandle) {
        Task {
            let run = await handle.finished()
            AccessibilityNotification.Announcement(BatchBarPresentation(run: run, currentName: nil).announcement).post()
        }
    }
}
