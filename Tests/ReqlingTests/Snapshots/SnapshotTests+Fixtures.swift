import Foundation
import ReqlingKit

@testable import Reqling

/// The project every snapshot draws from: a few requests, a folder, Default and Staging environments.
@MainActor
struct SnapshotProject {
    let id: ProjectID
    let listUsers: RequestNodeID
    let createUser: RequestNodeID
    let folder: RequestNodeID

    static func make(in fixture: AppFixture) throws -> SnapshotProject {
        let id = try fixture.library.createProject(named: "Sample API")
        let listUsers = RequestItem(name: "List users", kind: .http(HTTPRequestSpec(
            url: "{{baseUrl}}/users/{{userId}}",
            queryParameters: [
                KeyValuePair(key: "page", value: "{{page}}"),
                KeyValuePair(key: "trace", value: "{{$uuid}}"),
                KeyValuePair(key: "verbose", value: "1", isEnabled: false)
            ],
            headers: [KeyValuePair(key: "Accept", value: "application/json")]
        )))
        let createUser = RequestItem(name: "Create user", kind: .http(HTTPRequestSpec(
            method: .post,
            url: "{{baseUrl}}/users",
            body: .raw("{\n  \"name\": \"{{name}}\",\n  \"active\": true,\n  \"age\": 36\n}")
        )))
        let folder = RequestFolder(name: "Admin", auth: .bearer(token: "{{token}}"), children: [
            .request(RequestItem(name: "Purge cache", kind: .http(HTTPRequestSpec(method: "PURGE", url: "{{baseUrl}}/cache"))))
        ])
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "baseUrl", value: "https://api.example.com"),
                Variable(key: "page", value: "1"),
                Variable(key: "name", value: "Ada"),
                Variable(key: "token", value: "s3cr3t", isSecret: true)
            ]
            document.environments = [RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging.example.com")])]
            try document.insert(.request(listUsers), into: nil)
            try document.insert(.request(createUser), into: nil)
            try document.insert(.folder(folder), into: nil)
        }
        fixture.component.workspaceState.updateProject(id) { $0.expandedFolderIDs = [folder.id] }
        return SnapshotProject(id: id, listUsers: listUsers.id, createUser: createUser.id, folder: folder.id)
    }

    /// Selects a request, optionally replacing its spec first, and returns its editor.
    func editor(_ request: RequestNodeID, in fixture: AppFixture, spec: HTTPRequestSpec? = nil) throws -> RequestEditorViewModel {
        if let spec {
            try fixture.library.mutate(id) { try $0.updateRequest(request) { $0.kind = .http(spec) } }
        }
        fixture.model.selection = .node(id, request)
        return fixture.model.editor!
    }

    /// Stores an exchange as if a run had just finished, so the response pane has something to show.
    func cacheExchange(_ outcome: RequestExchange.Outcome, for request: RequestNodeID, in fixture: AppFixture) {
        ResponseCache(directory: fixture.profile.responsesDirectory).save(RequestExchange(
            projectID: id,
            requestID: request,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environmentName: "Default",
            request: ResolvedHTTPRequest(method: "GET", url: "https://api.example.com/users", headers: [], bodyPreview: nil, bodyByteCount: 0),
            outcome: outcome
        ))
    }
}
