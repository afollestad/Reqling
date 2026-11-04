import ReqlingKit

@testable import Reqling

/// Test-only shorthands; the app reaches these through `RequestEditor.editing` or the concrete editor.
extension RequestEditor {
    var projectID: ProjectID {
        editing.projectID
    }

    var requestID: RequestNodeID {
        editing.requestID
    }
}
