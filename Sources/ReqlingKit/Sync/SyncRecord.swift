import Foundation

/// A record zone: one per project, so deleting a project deletes everything it held at once, and `library` for what
/// every project shares. Names are the only zone identity CloudKit sees, so parsing them is strict.
enum SyncZone: Hashable, Sendable {
    case library
    case project(ProjectID)

    static let libraryName = "library"
    static let projectPrefix = "project-"

    var name: String {
        switch self {
        case .library: Self.libraryName
        case .project(let id): Self.projectPrefix + id.description
        }
    }

    /// `nil` for any name Reqling never writes, which a fetch ignores rather than acting on.
    init?(name: String) {
        if name == Self.libraryName {
            self = .library
        } else if name.hasPrefix(Self.projectPrefix),
                  let id = ProjectID(string: String(name.dropFirst(Self.projectPrefix.count))),
                  id.description == String(name.dropFirst(Self.projectPrefix.count)) {
            self = .project(id)
        } else {
            return nil
        }
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

    /// Whether a record of this kind may sit in `zone`; one anywhere else is ignored.
    func belongs(in zone: SyncZone) -> Bool {
        switch (self, zone) {
        case (.currentValues, _): true
        case (.globalEnvironment, .library), (.projectTombstone, .library): true
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
