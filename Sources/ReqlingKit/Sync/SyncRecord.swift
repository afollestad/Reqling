import Foundation

/// A record zone: one per project, so deleting a project deletes everything it held at once; beside each, the
/// project's `personal` zone, for what is this person's own rather than the project's (secret values and current
/// values), so the project's zone can be shared without them; and `library` for what every project shares. Names are
/// the only zone identity CloudKit sees, so parsing them is strict.
enum SyncZone: Hashable, Sendable {
    case library
    case project(ProjectID)
    case personal(ProjectID)

    static let libraryName = "library"
    static let projectPrefix = "project-"
    static let personalPrefix = "personal-"

    var name: String {
        switch self {
        case .library: Self.libraryName
        case .project(let id): Self.projectPrefix + id.description
        case .personal(let id): Self.personalPrefix + id.description
        }
    }

    /// The project the zone belongs to, if one.
    var project: ProjectID? {
        switch self {
        case .library: nil
        case .project(let id), .personal(let id): id
        }
    }

    /// `nil` for any name Reqling never writes, which a fetch ignores rather than acting on.
    init?(name: String) {
        if name == Self.libraryName {
            self = .library
        } else if let id = Self.projectID(in: name, after: Self.projectPrefix) {
            self = .project(id)
        } else if let id = Self.projectID(in: name, after: Self.personalPrefix) {
            self = .personal(id)
        } else {
            return nil
        }
    }

    /// The ID after `prefix`, only as Reqling writes one.
    private static func projectID(in name: String, after prefix: String) -> ProjectID? {
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(name.dropFirst(prefix.count))
        return ProjectID(string: suffix).flatMap { $0.description == suffix ? $0 : nil }
    }
}

/// What a record holds. Each kind lives in one kind of zone, so a record of the wrong kind there is ignored.
enum SyncRecordType: String, Hashable, Sendable, CaseIterable {
    case project = "Project"
    case folder = "Folder"
    case request = "Request"
    case environment = "Environment"
    case currentValues = "CurrentValues"
    case globalEnvironment = "GlobalEnvironment"
    case projectTombstone = "ProjectTombstone"
    /// One environment's secret values, as this person holds them.
    case personalSecrets = "PersonalSecrets"

    /// Whether a record of this kind may sit in `zone`; one anywhere else is ignored. Current values in a project's zone
    /// are where they lived before `personal` existed, read only to bring them over (`LibrarySync+PersonalData.swift`).
    func belongs(in zone: SyncZone) -> Bool {
        switch (self, zone) {
        case (.currentValues, _): true
        case (.globalEnvironment, .library), (.projectTombstone, .library), (.personalSecrets, .personal): true
        case (.project, .project), (.folder, .project), (.request, .project), (.environment, .project): true
        default: false
        }
    }
}

struct SyncRecordID: Hashable, Sendable, CustomStringConvertible {
    let zone: SyncZone
    let name: String

    var description: String {
        "\(zone.name)/\(name)"
    }

    static let projectName = "project"
    static let globalName = "global"
    static let currentValuesPrefix = "current-"
    static let secretsPrefix = "secrets-"
    static let tombstonePrefix = "tombstone-"
}

/// One record as sync reads and writes it, before the transport maps it onto a `CKRecord`, where every field below is
/// an encrypted value.
struct SyncRecord: Equatable, Sendable {
    let id: SyncRecordID
    var type: SyncRecordType
    /// The item's own fields, as JSON, with no secret values.
    var payload: OrderedJSON
    /// The secret values that go with `payload`, by the key the payload names them with; `nil` sends none and leaves the
    /// server's as they are, for a Mac that couldn't read its Keychain.
    var secrets: [String: String]?
    var formatVersion: Int
    var schemaVersion: Int
    /// When the edit that produced this version was made, which decides a field both Macs changed.
    var editedAt: Date
    /// The server's version of the record, opaque (`CKRecord.encodeSystemFields`); `nil` for one never saved.
    var systemFields: Data?
    /// When the server last saved it, which caps `editedAt`, so a Mac whose clock runs ahead can't win every field.
    var serverModifiedAt: Date?

    init(
        id: SyncRecordID,
        type: SyncRecordType,
        payload: OrderedJSON,
        secrets: [String: String]? = nil,
        formatVersion: Int = ProjectDocument.currentFormatVersion,
        schemaVersion: Int = ProjectRecordCoder.schemaVersion,
        editedAt: Date = .distantPast,
        systemFields: Data? = nil,
        serverModifiedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.secrets = secrets
        self.formatVersion = formatVersion
        self.schemaVersion = schemaVersion
        self.editedAt = editedAt
        self.systemFields = systemFields
        self.serverModifiedAt = serverModifiedAt
    }

    /// When the edit happened, as far as a merge may trust it.
    var trustedEditedAt: Date {
        serverModifiedAt.map { min(editedAt, $0) } ?? editedAt
    }
}
