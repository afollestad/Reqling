import ReqlingKit
import SwiftUI

/// A selected project: what it contains and where it lives. `DetailTitleBar` names it.
struct ProjectDetailView: View {
    let project: LibraryProject
    let model: AppModel

    var body: some View {
        if let document = project.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(project.url.abbreviatedPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 24) {
                        ProjectStat(value: document.allRequests.count, label: "Requests")
                        ProjectStat(value: document.allEnvironments.count, label: "Environments")
                        ProjectStat(value: document.tls.clientCertificates.count, label: "Client certificates")
                    }
                    if !project.issues.isEmpty {
                        ProjectIssues(issues: project.issues)
                    }
                    HStack {
                        Button("New Request") { model.newRequest(in: project.id) }
                            .buttonStyle(.borderedProminent)
                        Button("Environments…") { model.sheet = .environments(project.id) }
                        Button("Project Settings…") { model.sheet = .projectSettings(project.id) }
                        Button("Run Project…") { model.openBatchRun(BatchRunScope(projectID: project.id, folderID: nil)) }
                            .disabled(!model.canRunBatch(BatchRunScope(projectID: project.id, folderID: nil)))
                        Button("Reveal in Finder") { model.revealProject(project.id) }
                    }
                    if let scripts = model.containerScripts, scripts.projectID == project.id, scripts.folderID == nil {
                        ContainerScriptsSection(editor: scripts, model: model)
                        if document.hasScripts {
                            ProjectScriptTrustToggle(project: project.id, model: model)
                        }
                    }
                }
                .padding(AppMetrics.screenInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("Project Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                if case .unavailable(let reason) = project.status {
                    Text(reason)
                }
            } actions: {
                Button("Remove from Reqling") { model.removeProject(project.id) }
            }
        }
    }
}

/// Whether this project's scripts run on this Mac, the answer its trust question gave, changeable here.
private struct ProjectScriptTrustToggle: View {
    let project: ProjectID
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Run this project's scripts on this Mac", isOn: Binding(
                get: { model.scriptTrust(for: project) == .trusted },
                set: { model.setScriptTrust($0 ? .trusted : .declined, for: project) }
            ))
            .toggleStyle(.checkbox)
            Text("Scripts can read this project's variables and Global's, secrets included. Off, its requests run without them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// A folder's or the project's scripts, which run for every request inside, before the request's own.
private struct ContainerScriptsSection: View {
    let editor: ContainerScriptsEditor
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scripts")
                .font(.headline)
            Text(editor.folderID == nil
                ? "These run for every request in the project, before its folders' scripts and its own."
                : "These run for every request inside, before its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScriptsPane(scripts: editor.scripts, isReadOnly: editor.isReadOnly) { link in
                model.openScripts(link, phase: editor.scripts.phase, in: editor.projectID)
            }
            .frame(height: 280)
        }
    }
}

private struct ProjectStat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(value)")
                .font(.title.weight(.semibold).monospacedDigit())
            Text(label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectIssues: View {
    let issues: [ProjectLoadIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Some files could not be loaded", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            ForEach(issues, id: \.self) { issue in
                Text(issue.path.isEmpty ? issue.message : "\(issue.path): \(issue.message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A selected folder: the auth its requests inherit. `DetailTitleBar` names it and renames it.
struct FolderDetailView: View {
    let folder: RequestFolder
    let projectID: ProjectID
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(itemCount)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auth")
                        .font(.headline)
                    Text("Requests and folders inside that are set to Inherit use this.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AuthEditor(
                        auth: Binding(
                            get: { model.folderAuth(folder, in: projectID) },
                            set: { model.setAuth($0, forFolder: folder.id, in: projectID) }
                        ),
                        tokenContext: model.tokenContext(for: projectID)
                    )
                    // A read-only project refuses every save; editing it would only raise an alert per keystroke.
                    .disabled(isReadOnly)
                }
                if let scripts = model.containerScripts, scripts.projectID == projectID, scripts.folderID == folder.id {
                    ContainerScriptsSection(editor: scripts, model: model)
                }
                HStack {
                    Button("New Request") { model.newRequest(in: projectID) }
                    Button("New Folder") { model.newFolder(in: projectID) }
                    Button("Run Folder…") { model.openBatchRun(BatchRunScope(projectID: projectID, folderID: folder.id)) }
                        .disabled(!model.canRunBatch(BatchRunScope(projectID: projectID, folderID: folder.id)))
                }
            }
            .padding(AppMetrics.screenInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isReadOnly: Bool {
        model.library.project(projectID)?.isReadOnly ?? true
    }

    private var itemCount: String {
        "\(folder.children.count) item\(folder.children.count == 1 ? "" : "s")"
    }
}
