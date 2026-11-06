import ReqlingKit

/// What the window's title bar names: the shown detail, and whether it can be renamed in place there.
struct DetailTitle: Equatable {
    enum Subject: Hashable {
        case app
        case settings
        case project(ProjectID)
        case node(ProjectID, RequestNodeID)
    }

    let text: String
    let subject: Subject
    /// False for the app and Settings, and for anything in a project that is read-only or did not load, where a rename
    /// would only raise an alert.
    let isRenamable: Bool
}

extension AppModel {
    /// Follows `DetailView`'s precedence, so the title always names what the detail shows: Settings, then the request
    /// editor (which outlives its project going unavailable, to keep the draft), then the selection, falling back to
    /// the project when a selected item's project did not load.
    var detailTitle: DetailTitle {
        if isShowingSettings {
            return DetailTitle(text: "Settings", subject: .settings, isRenamable: false)
        }
        if let editor = editor?.editing {
            return DetailTitle(text: editor.name, subject: .node(editor.projectID, editor.requestID), isRenamable: !editor.isReadOnly)
        }
        guard let selection, let project = library.project(selection.projectID) else {
            return DetailTitle(text: appInfo.name, subject: .app, isRenamable: false)
        }
        if let nodeID = selection.nodeID, let node = project.document?.node(nodeID) {
            return DetailTitle(text: node.name, subject: .node(project.id, nodeID), isRenamable: canRename(.node(project.id, nodeID)))
        }
        return DetailTitle(text: project.name, subject: .project(project.id), isRenamable: canRename(.project(project.id)))
    }

    /// Renames `subject` rather than the current title's, so an inline edit committed as the selection moves away
    /// still renames what it started on.
    func rename(_ subject: DetailTitle.Subject, to name: String) {
        switch subject {
        case .app, .settings:
            break
        case .project(let project):
            renameProject(project, to: name)
        case .node(let project, let node):
            rename(node, in: project, to: name)
        }
    }
}
