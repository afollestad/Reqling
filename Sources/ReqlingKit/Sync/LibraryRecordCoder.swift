import Foundation

/// The records outside a project's folder: Global, current values, and the tombstone a deletion leaves.
///
/// Current values live beside what they belong to: an environment's in its project's zone, so deleting the project
/// deletes them too, and Global's in `library`.
enum LibraryRecordCoder {
    static let globalRecordID = SyncRecordID(zone: .library, name: SyncRecordID.globalName)

    // MARK: - Global

    /// Global's record. `secrets` is its Keychain item, or `nil` when it couldn't be read.
    static func globalRecord(_ environment: RequestEnvironment, secrets: [String: String]?) throws -> SyncRecord {
        SyncRecord(
            id: globalRecordID,
            type: .globalEnvironment,
            payload: try ProjectRecordCoder.json(GlobalEnvironmentFile(variables: environment.variables)),
            secrets: secrets.map { ProjectRecordCoder.secretValues(of: environment, from: $0) }
        )
    }

    /// Global's variables from its record, with the secret values that came along to store by `SecretKey`; one that
    /// didn't keeps `local`'s.
    static func global(from record: SyncRecord, local: RequestEnvironment) throws -> (variables: [Variable], secrets: [String: String]) {
        var variables = try ProjectRecordCoder.decode(GlobalEnvironmentFile.self, from: record).variables
        var secrets: [String: String] = [:]
        for index in variables.indices where variables[index].isSecret {
            let id = variables[index].id
            if let value = record.secrets?[id.description] {
                variables[index].value = value
                secrets[SecretKey.variable(id, in: RequestEnvironment.globalID)] = value
            } else {
                variables[index].value = local.variables.first { $0.id == id && $0.isSecret }?.value ?? ""
            }
        }
        return (variables, secrets)
    }

    // MARK: - Current values

    static func currentValuesRecordID(_ scope: CurrentValueScope) -> SyncRecordID {
        switch scope {
        case .global:
            SyncRecordID(zone: .library, name: SyncRecordID.currentValuesPrefix + SyncRecordID.globalName)
        case .environment(let project, let environment):
            SyncRecordID(zone: .project(project), name: SyncRecordID.currentValuesPrefix + environment.description)
        }
    }

    /// The scope a current-values record holds, or `nil` for a name Reqling never writes.
    static func scope(of id: SyncRecordID) -> CurrentValueScope? {
        guard id.name.hasPrefix(SyncRecordID.currentValuesPrefix) else {
            return nil
        }
        let suffix = String(id.name.dropFirst(SyncRecordID.currentValuesPrefix.count))
        switch id.zone {
        case .library:
            return suffix == SyncRecordID.globalName ? .global : nil
        case .project(let project):
            return EnvironmentID(string: suffix).map { .environment(project, $0) }
        }
    }

    /// One scope's current values. A secret one's value comes from `secrets` (the account's Keychain item), and is left
    /// out when that couldn't be read.
    static func currentValuesRecord(
        _ scope: CurrentValueScope,
        values: [String: StoredCurrentValue],
        secrets: [String: String]?
    ) throws -> SyncRecord {
        var secretValues: [String: String]?
        if let secrets {
            var held: [String: String] = [:]
            for (key, value) in values where value == .secret {
                held[key] = secrets[SecretKey.currentValue(key, in: scope.environmentID)]
            }
            secretValues = held
        }
        return SyncRecord(
            id: currentValuesRecordID(scope),
            type: .currentValues,
            payload: try ProjectRecordCoder.json(values),
            secrets: secretValues
        )
    }

    /// A scope's values and markers, and the secret values that came along, by key.
    static func currentValues(from record: SyncRecord) throws -> (values: [String: StoredCurrentValue], secrets: [String: String]) {
        (try ProjectRecordCoder.decode([String: StoredCurrentValue].self, from: record), record.secrets ?? [:])
    }

    // MARK: - Tombstones

    static func tombstoneRecordID(_ project: ProjectID) -> SyncRecordID {
        SyncRecordID(zone: .library, name: SyncRecordID.tombstonePrefix + project.description)
    }

    /// Written before a deleted project's zone goes, so another Mac can tell a deletion someone made from a zone that
    /// vanished any other way, and only then moves its copy to the Trash.
    static func tombstoneRecord(_ project: ProjectID) throws -> SyncRecord {
        SyncRecord(id: tombstoneRecordID(project), type: .projectTombstone, payload: try ProjectRecordCoder.json(["project": project]))
    }

    /// The project a tombstone names, or `nil` for a name Reqling never writes.
    static func tombstonedProject(_ id: SyncRecordID) -> ProjectID? {
        guard id.zone == .library, id.name.hasPrefix(SyncRecordID.tombstonePrefix) else {
            return nil
        }
        return ProjectID(string: String(id.name.dropFirst(SyncRecordID.tombstonePrefix.count)))
    }
}
