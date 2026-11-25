import Foundation

/// The records outside a project's folder: Global, this person's secret values and current values, and the tombstone a
/// deletion leaves.
///
/// A project's secret values and current values live in its `personal` zone, apart from the project's own, so sharing
/// the project never shares them; Global's live in `library`.
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
            SyncRecordID(zone: .personal(project), name: SyncRecordID.currentValuesPrefix + environment.description)
        }
    }

    /// The scope a current-values record holds, or `nil` for a name Reqling never writes. One in a project's own zone is
    /// where an environment's lived before `personal` existed.
    static func scope(of id: SyncRecordID) -> CurrentValueScope? {
        guard id.name.hasPrefix(SyncRecordID.currentValuesPrefix) else {
            return nil
        }
        let suffix = String(id.name.dropFirst(SyncRecordID.currentValuesPrefix.count))
        switch id.zone {
        case .library:
            return suffix == SyncRecordID.globalName ? .global : nil
        case .project(let project), .personal(let project):
            return EnvironmentID(string: suffix).flatMap { $0.description == suffix ? .environment(project, $0) : nil }
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

    // MARK: - Secret values

    static func secretsRecordID(_ project: ProjectID, _ environment: EnvironmentID) -> SyncRecordID {
        SyncRecordID(zone: .personal(project), name: SyncRecordID.secretsPrefix + environment.description)
    }

    /// The environment whose secret values a record holds, or `nil` for a name Reqling never writes.
    static func secretsEnvironment(_ id: SyncRecordID) -> EnvironmentID? {
        guard case .personal = id.zone, id.name.hasPrefix(SyncRecordID.secretsPrefix) else {
            return nil
        }
        let suffix = String(id.name.dropFirst(SyncRecordID.secretsPrefix.count))
        return EnvironmentID(string: suffix).flatMap { $0.description == suffix ? $0 : nil }
    }

    /// `environment`'s secret values this Mac holds, by variable ID, from `secrets` (the project's Keychain item), or
    /// none at all when that couldn't be read. Its payload is empty: the variables themselves are the project's.
    static func secretsRecord(_ project: ProjectID, _ environment: RequestEnvironment, secrets: [String: String]?) -> SyncRecord {
        SyncRecord(
            id: secretsRecordID(project, environment.id),
            type: .personalSecrets,
            payload: .object([]),
            secrets: secrets.map { ProjectRecordCoder.secretValues(of: environment, from: $0) }
        )
    }

    /// Every value `keychain` (the project's Keychain item) holds for `environment`'s variables, as a secrets record,
    /// whether or not its project is listed here to say which variables are secret.
    static func secretsRecord(_ project: ProjectID, _ environment: EnvironmentID, keychain: [String: String]) -> SyncRecord {
        let prefix = SecretKey.variablePrefix + environment.description + "."
        var secrets: [String: String] = [:]
        for (key, value) in keychain where key.hasPrefix(prefix) {
            secrets[String(key.dropFirst(prefix.count))] = value
        }
        return SyncRecord(id: secretsRecordID(project, environment), type: .personalSecrets, payload: .object([]), secrets: secrets)
    }

    /// A secrets record's values to store, by `SecretKey`; a variable ID Reqling never writes is skipped.
    static func secretValues(from record: SyncRecord) -> [String: String] {
        guard let environment = secretsEnvironment(record.id) else {
            return [:]
        }
        var values: [String: String] = [:]
        for (key, value) in record.secrets ?? [:] {
            if let variable = VariableID(string: key), variable.description == key {
                values[SecretKey.variable(variable, in: environment)] = value
            }
        }
        return values
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
