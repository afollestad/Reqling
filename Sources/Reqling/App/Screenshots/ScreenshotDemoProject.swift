#if DEBUG
import Foundation
import ReqlingKit

/// The projects screenshot mode shows: a finished-looking "Acme API" with HTTP and gRPC requests, environments, and a
/// cached last run for each request a scene opens, plus a second project so the sidebar reads as a library. That one,
/// Storefront, holds the GraphQL scene's request and stays collapsed in every other scene, where its row still shows
/// how many requests it holds: keep that at two, or every other capture changes.
/// Every value is fixed, so the light and dark captures of a scene match and one `alt` describes both. The website's
/// alt text (the `gh-pages` branch) describes this data, so recapture with `scripts/screenshots.sh` and update it there
/// when it changes.
@MainActor
enum ScreenshotDemoProject {
    /// When every cached run started; the panes show durations and offsets, never this date.
    fileprivate static let startedAt = Date(timeIntervalSince1970: 1_793_000_000)

    static func seed(_ scene: ScreenshotMode.Scene, into component: AppComponent) throws {
        let library = component.projectLibrary
        let storefront = try seedStorefront(expanded: scene == .graphql, into: component)
        let search = StorefrontSearch.request

        let acme = try library.createProject(named: "Acme API")
        guard let acmeURL = library.project(acme)?.url else {
            throw CocoaError(.fileNoSuchFile)
        }
        try GreeterDescriptorSet.data.write(to: acmeURL.appendingPathComponent(GreeterDescriptorSet.fileName))
        let requests = DemoRequests()
        try library.mutate(acme) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "baseUrl", value: "https://api.acme.dev"),
                Variable(key: "userId", value: "42"),
                Variable(key: "name", value: "Grace Hopper"),
                Variable(key: "grpcHost", value: "greeter.acme.dev:443"),
                Variable(key: "token", value: "demo-token", isSecret: true)
            ]
            let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging.api.acme.dev")])
            document.environments = [staging, RequestEnvironment(name: "Production")]
            for node in requests.nodes {
                try document.insert(node, into: nil)
            }
        }
        component.workspaceState.updateProject(acme) { $0.expandedFolderIDs = requests.expandedFolderIDs }

        let history = RunHistoryStore(directory: component.storageProfile.historyDirectory)
        let runs = requests.cachedRuns.map { (acme, $0) } + [(storefront, StorefrontSearch.cachedRun(of: search.id))]
        for (project, run) in runs {
            history.save(RequestExchange(
                projectID: project,
                requestID: run.request,
                startedAt: startedAt,
                environmentName: "Default",
                request: run.sent,
                outcome: run.outcome
            ))
        }

        let shown = switch scene {
        case .request: WorkspaceSelection(projectID: acme, nodeID: requests.getUser)
        case .body: WorkspaceSelection(projectID: acme, nodeID: requests.createUser)
        case .grpc: WorkspaceSelection(projectID: acme, nodeID: requests.chat)
        case .graphql: WorkspaceSelection(projectID: storefront, nodeID: search.id)
        }
        component.workspaceState.update { state in
            state.selection = shown
            if scene == .graphql {
                state.showsRunHistory = true
                state.inspectorPanel = .graphQLSchema
            }
        }
        showTabs(for: scene, in: component.appModel)
    }

    /// Created first, so it sits above Acme API in the sidebar.
    private static func seedStorefront(expanded: Bool, into component: AppComponent) throws -> ProjectID {
        let library = component.projectLibrary
        let storefront = try library.createProject(named: "Storefront")
        guard let storefrontURL = library.project(storefront)?.url else {
            throw CocoaError(.fileNoSuchFile)
        }
        try StorefrontGraphQLSchema.sdl.write(
            to: storefrontURL.appendingPathComponent(StorefrontGraphQLSchema.fileName),
            atomically: true,
            encoding: .utf8
        )
        try library.mutate(storefront) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "baseUrl", value: "https://shop.acme.dev"),
                Variable(key: "searchTerm", value: "mug")
            ]
            try document.insert(.request(StorefrontSearch.request), into: nil)
            try document.insert(.request(DemoRequests.http("Checkout", .post, url: "{{baseUrl}}/checkout")), into: nil)
        }
        component.workspaceState.updateProject(storefront) { $0.isCollapsed = !expanded }
        return storefront
    }

    /// The editor and response tabs each scene shows; `AppModel` built its editor from the seeded selection.
    private static func showTabs(for scene: ScreenshotMode.Scene, in model: AppModel) {
        switch scene {
        case .request:
            model.editor?.asHTTP?.tab = .params
        case .body:
            model.editor?.asHTTP?.tab = .body
            model.editor?.asHTTP?.response.tab = .timing
        case .grpc:
            model.editor?.asGRPC?.tab = .messages
        case .graphql:
            model.editor?.asHTTP?.tab = .body
            model.editor?.asHTTP?.graphQL?.browser.show("Product")
        }
    }
}

/// Storefront's GraphQL request, and the run cached for it.
@MainActor
private enum StorefrontSearch {
    static let request = RequestItem(name: "Search products", kind: .http(HTTPRequestSpec(
        method: .post,
        url: "{{baseUrl}}/graphql",
        body: HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: """
            query Search($query: String!) {
              search(query: $query, first: 2) {
                totalCount
                nodes {
                  title
                  handle
                  priceRange {
                    min { amount currencyCode }
                  }
                }
              }
            }
            """,
            variables: "{\n  \"query\": \"{{searchTerm}}\"\n}",
            operationName: "Search",
            schema: .file(.relative(StorefrontGraphQLSchema.fileName))
        ))
    )))

    static func cachedRun(of request: RequestNodeID) -> CachedRun {
        let url = "https://shop.acme.dev/graphql"
        let response = HTTPResponseRecord(
            statusCode: 200,
            headers: [KeyValuePair(key: "Content-Type", value: "application/graphql-response+json; charset=utf-8")],
            body: Data("""
            {"data":{"search":{"totalCount":14,"nodes":[\
            {"title":"Enamel Camp Mug","handle":"enamel-camp-mug","priceRange":{"min":{"amount":"18.00","currencyCode":"USD"}}},\
            {"title":"Stoneware Mug","handle":"stoneware-mug","priceRange":{"min":{"amount":"24.00","currencyCode":"USD"}}}]}}}
            """.utf8),
            url: url,
            startedAt: ScreenshotDemoProject.startedAt,
            duration: 0.094,
            timing: HTTPTiming(dnsLookup: 0.003, connect: 0.010, tlsHandshake: 0.021, requestSent: 0.0003, waiting: 0.052, download: 0.008),
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
        let sent = ResolvedHTTPRequest(method: "POST", url: url, headers: [], bodyPreview: nil, bodyByteCount: 0)
        return CachedRun(request: request, sent: sent, outcome: .response(response))
    }
}

/// A run stored as if it had just finished, so the response pane shows it.
private struct CachedRun {
    let request: RequestNodeID
    let sent: ResolvedHTTPRequest?
    let outcome: RequestExchange.Outcome
}

/// Acme API's folders and requests, and the runs cached for the ones a scene opens.
@MainActor
private struct DemoRequests {
    let getUser: RequestNodeID
    let createUser: RequestNodeID
    let chat: RequestNodeID
    let nodes: [RequestNode]
    let expandedFolderIDs: Set<RequestNodeID>
    let cachedRuns: [CachedRun]

    init() {
        let getUser = Self.getUserRequest
        let createUser = Self.createUserRequest
        let chat = Self.grpc("Chat", method: "Chat")
        let users = RequestFolder(name: "Users", auth: .bearer(token: "{{token}}"), children: [
            .request(Self.http("List users", url: "{{baseUrl}}/users")),
            .request(getUser),
            .request(createUser),
            .request(Self.http("Delete user", .delete, url: "{{baseUrl}}/users/{{userId}}"))
        ])
        let orders = RequestFolder(name: "Orders", children: [
            .request(Self.http("List orders", url: "{{baseUrl}}/orders")),
            .request(Self.http("Refund order", .patch, url: "{{baseUrl}}/orders/{{orderId}}"))
        ])
        let greeter = RequestFolder(name: "Greeter", children: [.request(Self.grpc("Say hello", method: "SayHello")), .request(chat)])
        self.getUser = getUser.id
        self.createUser = createUser.id
        self.chat = chat.id
        nodes = [
            .folder(users),
            .folder(orders),
            .folder(greeter),
            .request(Self.http("Health check", url: "{{baseUrl}}/health")),
            .request(Self.http("Purge cache", "PURGE", url: "{{baseUrl}}/cache"))
        ]
        expandedFolderIDs = [users.id, greeter.id]
        cachedRuns = [
            CachedRun(request: getUser.id, sent: Self.sent("GET", "/users/42?include=roles,team"), outcome: .response(Self.userResponse)),
            CachedRun(request: createUser.id, sent: Self.sent("POST", "/users"), outcome: .response(Self.createdResponse)),
            CachedRun(request: chat.id, sent: nil, outcome: .grpc(Self.chatRecord))
        ]
    }

    static func http(_ name: String, _ method: HTTPMethod = .get, url: String) -> RequestItem {
        RequestItem(name: name, kind: .http(HTTPRequestSpec(method: method, url: url)))
    }

    private static func grpc(_ name: String, method: String) -> RequestItem {
        RequestItem(name: name, kind: .grpc(GRPCRequestSpec(
            target: "{{grpcHost}}",
            security: .tls,
            service: GreeterDescriptorSet.service,
            method: method,
            // One saved message, so the editor shows it whole; the Chat call sent its second from the open stream.
            messages: ["{\n  \"name\": \"{{name}}\"\n}"],
            schema: .descriptorSet(.relative(GreeterDescriptorSet.fileName))
        )))
    }

    private static var getUserRequest: RequestItem {
        RequestItem(name: "Get user", kind: .http(HTTPRequestSpec(
            url: "{{baseUrl}}/users/{{userId}}",
            queryParameters: [
                KeyValuePair(key: "include", value: "roles,team"),
                KeyValuePair(key: "trace", value: "{{$uuid}}"),
                KeyValuePair(key: "verbose", value: "1", isEnabled: false)
            ],
            headers: [KeyValuePair(key: "Accept", value: "application/json")]
        )))
    }

    private static var createUserRequest: RequestItem {
        RequestItem(name: "Create user", kind: .http(HTTPRequestSpec(
            method: .post,
            url: "{{baseUrl}}/users",
            body: .raw("""
            {
              "name": "{{name}}",
              "email": "grace@acme.dev",
              "roles": ["member", "billing"],
              "sendInvite": true,
              "requestId": "{{$uuid}}"
            }
            """, contentType: "application/json")
        )))
    }

    private static func sent(_ method: String, _ path: String) -> ResolvedHTTPRequest {
        ResolvedHTTPRequest(method: method, url: "https://api.acme.dev\(path)", headers: [], bodyPreview: nil, bodyByteCount: 0)
    }

    private static var userResponse: HTTPResponseRecord {
        HTTPResponseRecord(
            statusCode: 200,
            headers: [
                KeyValuePair(key: "Content-Type", value: "application/json; charset=utf-8"),
                KeyValuePair(key: "Cache-Control", value: "private, max-age=60"),
                KeyValuePair(key: "X-Request-Id", value: "6f1c2a9e-4b7d-4e0a-9c3f-2d8e5b1a7c64")
            ],
            body: Data("""
            {"id":42,"name":"Ada Lovelace","email":"ada@acme.dev","active":true,"roles":["admin","billing"],\
            "team":{"id":7,"name":"Analytical Engines"},"createdAt":"2026-03-14T09:26:53Z","lastSeenAt":null}
            """.utf8),
            url: "https://api.acme.dev/users/42?include=roles,team",
            startedAt: ScreenshotDemoProject.startedAt,
            duration: 0.086,
            timing: HTTPTiming(dnsLookup: 0.003, connect: 0.009, tlsHandshake: 0.018, requestSent: 0.0002, waiting: 0.049, download: 0.007),
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
    }

    private static var createdResponse: HTTPResponseRecord {
        HTTPResponseRecord(
            statusCode: 201,
            headers: [
                KeyValuePair(key: "Content-Type", value: "application/json; charset=utf-8"),
                KeyValuePair(key: "Location", value: "/users/43")
            ],
            body: Data(#"{"id":43,"name":"Grace Hopper","email":"grace@acme.dev","roles":["member","billing"],"invited":true}"#.utf8),
            url: "https://api.acme.dev/users",
            startedAt: ScreenshotDemoProject.startedAt,
            duration: 0.142,
            timing: HTTPTiming(dnsLookup: 0.004, connect: 0.012, tlsHandshake: 0.026, requestSent: 0.0003, waiting: 0.088, download: 0.011),
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
    }

    /// Byte counts are the messages' protobuf encodings: two bytes of tag and length per field, plus the strings.
    private static var chatRecord: GRPCCallRecord {
        let events = [
            GRPCMessageEvent(direction: .sent, offset: 0.006, json: "{\n  \"name\": \"Grace Hopper\"\n}", byteCount: 14, sequence: 0),
            GRPCMessageEvent(
                direction: .received,
                offset: 0.017,
                json: "{\n  \"message\": \"Hello, Grace Hopper!\",\n  \"count\": 1\n}",
                byteCount: 24,
                sequence: 1
            ),
            GRPCMessageEvent(
                direction: .sent, offset: 0.025, json: "{\n  \"name\": \"Ada\",\n  \"mood\": \"MOOD_CHEERFUL\"\n}", byteCount: 7, sequence: 2
            ),
            GRPCMessageEvent(
                direction: .received,
                offset: 0.036,
                json: "{\n  \"message\": \"Hello, Ada! Glad you're cheerful.\",\n  \"count\": 2\n}",
                byteCount: 37,
                sequence: 3
            )
        ]
        return GRPCCallRecord(
            target: "greeter.acme.dev:443",
            method: "\(GreeterDescriptorSet.service)/Chat",
            kind: .bidirectionalStreaming,
            sentMetadata: [KeyValuePair(key: "authorization", value: "Bearer ••••••••")],
            initialMetadata: [KeyValuePair(key: "content-type", value: "application/grpc"), KeyValuePair(key: "server", value: "greeter/1.4")],
            trailers: [KeyValuePair(key: "grpc-status", value: "0")],
            events: events,
            status: GRPCStatusRecord(code: 0, name: "OK", message: ""),
            duration: 0.048
        )
    }
}
#endif
