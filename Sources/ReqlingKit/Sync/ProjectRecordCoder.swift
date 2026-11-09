import Foundation

/// A project as records, and records as a project. Each folder, request, and environment is its own record, so two Macs
/// editing different items never conflict; membership travels as each item's `parentID` and order as each parent's
/// list of IDs, since slugs are this Mac's file names.
///
/// Payloads carry no secret values: `Variable.encode` strips them, and they travel in the record's `secrets`, keyed by
/// variable ID. A record decodes only into what this version understands; `LibrarySync` defers a project whose
/// records it can't read rather than guessing.
enum ProjectRecordCoder {
    /// Bumped whenever a payload's encoded keys change, so an older Mac defers what it would otherwise strip.
    /// `ProjectRecordCoderTests.testThePayloadSchemaMatchesItsVersion` fails until it is.
    static let schemaVersion = 1
    /// Nesting beyond this is refused, since the writer and the tree helpers recurse.
    static let maxDepth = 64
    static let maxItems = 20_000

    // MARK: - Encoding

    /// Every record of `document`. `secrets` is the project's Keychain item, or `nil` when it couldn't be read, which
    /// sends no secret values at all rather than blanks. A secret this Mac has no value for is left out, never sent empty.
    static func records(for document: ProjectDocument, secrets: [String: String]?) throws -> [SyncRecordID: SyncRecord] {
        let zone = SyncZone.project(document.id)
        var records: [SyncRecordID: SyncRecord] = [:]
        func add(_ name: String, _ type: SyncRecordType, _ payload: some Encodable, secrets: [String: String]? = nil) throws {
            let id = SyncRecordID(zone: zone, name: name)
            records[id] = SyncRecord(id: id, type: type, payload: try json(payload), secrets: secrets)
        }
        try add(SyncRecordID.projectName, .project, ProjectPayload(document))
        func addNodes(_ nodes: [RequestNode], parent: RequestNodeID?) throws {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    try add(folder.id.description, .folder, FolderPayload(folder, parent: parent))
                    try addNodes(folder.children, parent: folder.id)
                case .request(let request):
                    try add(request.id.description, .request, RequestPayload(item: request, parentID: parent))
                }
            }
        }
        try addNodes(document.items, parent: nil)
        for environment in document.allEnvironments {
            try add(environment.id.description, .environment, environment, secrets: secrets.map { secretValues(of: environment, from: $0) })
        }
        return records
    }

    /// `environment`'s secret values this Mac holds, by variable ID.
    static func secretValues(of environment: RequestEnvironment, from secrets: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for variable in environment.variables where variable.isSecret {
            if let value = secrets[SecretKey.variable(variable.id, in: environment.id)] {
                values[variable.id.description] = value
            }
        }
        return values
    }

    // MARK: - Decoding

    /// What a zone's records make: the document, and the secret values that came with it to store, by `SecretKey`.
    struct Decoded {
        var document: ProjectDocument
        var secrets: [String: String]
    }

    /// Builds the project from every record its zone holds. A secret whose value didn't come along keeps `local`'s, so an
    /// absent value never blanks one. Membership comes from `parentID` alone; an item whose folder is gone goes to the
    /// top level, and a cycle two Macs' moves made is broken at its lowest ID, so every Mac repairs alike.
    static func document(
        _ project: ProjectID,
        from records: some Collection<SyncRecord>,
        local: ProjectDocument?
    ) throws -> Decoded {
        guard records.count <= maxItems else {
            throw SyncRecordError.tooLarge
        }
        let parts = try Parts(records)
        var tree = SyncTreeAssembler(
            folders: parts.folders.mapValues { (parent: $0.parentID, order: $0.order) },
            requests: parts.requests.mapValues(\.parentID),
            rootOrder: parts.header.itemOrder
        )
        let items = try tree.assemble(maxDepth: maxDepth) { id, children in
            if let folder = parts.folders[id] {
                return .folder(folder.folder(children: children))
            }
            return parts.requests[id].map { .request($0.item) }
        }
        let header = parts.header
        guard let defaultEnvironment = parts.environments[header.defaultEnvironmentID] else {
            throw SyncRecordError.missingDefaultEnvironment
        }
        var secrets: [String: String] = [:]
        let others = ordered(parts.environments.keys.filter { $0 != header.defaultEnvironmentID }, by: header.environmentOrder)
        let document = ProjectDocument(
            id: project,
            name: header.name,
            auth: header.auth,
            tls: header.tls,
            grpc: header.grpc,
            scripts: header.scripts.set,
            defaultEnvironment: filled(defaultEnvironment, local: local, storing: &secrets),
            environments: others.compactMap { parts.environments[$0] }.map { filled($0, local: local, storing: &secrets) },
            items: items
        )
        return Decoded(document: document, secrets: secrets)
    }

    /// A zone's records decoded by kind.
    private struct Parts {
        var header: ProjectPayload
        var folders: [RequestNodeID: FolderPayload] = [:]
        var requests: [RequestNodeID: RequestPayload] = [:]
        var environments: [EnvironmentID: (environment: RequestEnvironment, secrets: [String: String]?)] = [:]

        init(_ records: some Collection<SyncRecord>) throws {
            guard let projectRecord = records.first(where: { $0.type == .project }) else {
                throw SyncRecordError.missingProject
            }
            header = try decode(ProjectPayload.self, from: projectRecord)
            for record in records {
                switch record.type {
                case .folder:
                    let folder = try decode(FolderPayload.self, from: record)
                    folders[folder.id] = folder
                case .request:
                    let request = try decode(RequestPayload.self, from: record)
                    requests[request.item.id] = request
                case .environment:
                    let environment = try decode(RequestEnvironment.self, from: record)
                    environments[environment.id] = (environment, record.secrets)
                case .project, .currentValues, .globalEnvironment, .projectTombstone:
                    continue
                }
            }
        }
    }

    /// The environment with each secret's value: the one that came along, stored, else `local`'s.
    private static func filled(
        _ synced: (environment: RequestEnvironment, secrets: [String: String]?),
        local: ProjectDocument?,
        storing stored: inout [String: String]
    ) -> RequestEnvironment {
        var environment = synced.environment
        let held = local?.environment(environment.id)
        for index in environment.variables.indices where environment.variables[index].isSecret {
            let variable = environment.variables[index]
            if let value = synced.secrets?[variable.id.description] {
                environment.variables[index].value = value
                stored[SecretKey.variable(variable.id, in: environment.id)] = value
            } else {
                environment.variables[index].value = held?.variables.first { $0.id == variable.id && $0.isSecret }?.value ?? ""
            }
        }
        return environment
    }

    /// `ids` in `order`'s order, then any it doesn't list by ID, so every Mac places them alike.
    static func ordered<ID: Hashable & CustomStringConvertible>(_ ids: some Collection<ID>, by order: [ID]) -> [ID] {
        let present = Set(ids)
        var seen: Set<ID> = []
        let listed = order.filter { present.contains($0) && seen.insert($0).inserted }
        return listed + ids.filter { !seen.contains($0) }.sorted { $0.description < $1.description }
    }

    // MARK: - JSON

    static func json(_ value: some Encodable) throws -> OrderedJSON {
        guard let text = String(bytes: try ProjectJSON.encode(value), encoding: .utf8) else {
            throw SyncRecordError.unencodable
        }
        return try OrderedJSONParser.parse(text)
    }

    static func decode<T: Decodable>(_ type: T.Type, from record: SyncRecord) throws -> T {
        do {
            return try ProjectJSON.decode(type, from: Data(record.payload.prettyPrinted().utf8))
        } catch {
            throw SyncRecordError.unreadable(record.id)
        }
    }
}

enum SyncRecordError: Error, Equatable {
    case missingProject
    case missingDefaultEnvironment
    case unreadable(SyncRecordID)
    case tooLarge
    case tooDeep
    case unencodable
}

/// A project's own fields, its top-level order, and which environment is Default.
private struct ProjectPayload: Codable {
    var name: String
    var auth: HTTPAuth
    var tls: ProjectTLSConfiguration
    var grpc: ProjectGRPCConfiguration
    var scripts: SyncScripts
    var itemOrder: [RequestNodeID]
    var environmentOrder: [EnvironmentID]
    var defaultEnvironmentID: EnvironmentID

    init(_ document: ProjectDocument) {
        name = document.name
        auth = document.auth
        tls = document.tls
        grpc = document.grpc
        scripts = SyncScripts(document.scripts)
        itemOrder = document.items.map(\.id)
        environmentOrder = document.environments.map(\.id)
        defaultEnvironmentID = document.defaultEnvironment.id
    }
}

/// A folder's own fields, where it sits, and its children's order.
private struct FolderPayload: Codable {
    var id: RequestNodeID
    var name: String
    var auth: HTTPAuth
    var inheritScripts: Bool
    var scripts: SyncScripts
    var parentID: RequestNodeID?
    var order: [RequestNodeID]

    init(_ folder: RequestFolder, parent: RequestNodeID?) {
        id = folder.id
        name = folder.name
        auth = folder.auth
        inheritScripts = folder.runsInheritedScripts
        scripts = SyncScripts(folder.scripts)
        parentID = parent
        order = folder.children.map(\.id)
    }

    func folder(children: [RequestNode]) -> RequestFolder {
        RequestFolder(id: id, name: name, auth: auth, scripts: scripts.set, runsInheritedScripts: inheritScripts, children: children)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, auth, inheritScripts, scripts, parentID, order
    }

    /// `parentID` is written even when `nil`, so moving to the top level is an edit two Macs' merge compares, not a
    /// removal that an edit elsewhere would beat.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(auth, forKey: .auth)
        try container.encode(inheritScripts, forKey: .inheritScripts)
        try container.encode(scripts, forKey: .scripts)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(order, forKey: .order)
    }
}

/// A request's file fields, with its scripts and where it sits.
private struct RequestPayload: Codable {
    var item: RequestItem
    var parentID: RequestNodeID?

    init(item: RequestItem, parentID: RequestNodeID?) {
        self.item = item
        self.parentID = parentID
    }

    private enum CodingKeys: String, CodingKey {
        case scripts, parentID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var item = try RequestItem(from: decoder)
        item.scripts = try container.decodeIfPresent(SyncScripts.self, forKey: .scripts)?.set ?? ScriptSet()
        self.item = item
        parentID = try container.decodeIfPresent(RequestNodeID.self, forKey: .parentID)
    }

    /// Flat, as a request file is, with `parentID` written even when `nil` (see `FolderPayload`).
    func encode(to encoder: any Encoder) throws {
        try item.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncScripts(item.scripts), forKey: .scripts)
        try container.encode(parentID, forKey: .parentID)
    }
}

/// A `ScriptSet` as JSON; scripts are files on disk, so the file models never code them.
struct SyncScripts: Codable, Equatable {
    var preRequest: String
    var stream: String
    var postResponse: String

    init(_ set: ScriptSet) {
        preRequest = set.preRequest
        stream = set.stream
        postResponse = set.postResponse
    }

    var set: ScriptSet {
        ScriptSet(preRequest: preRequest, stream: stream, postResponse: postResponse)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preRequest = try container.decodeIfPresent(String.self, forKey: .preRequest) ?? ""
        stream = try container.decodeIfPresent(String.self, forKey: .stream) ?? ""
        postResponse = try container.decodeIfPresent(String.self, forKey: .postResponse) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case preRequest, stream, postResponse
    }
}
