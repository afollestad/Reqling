import Foundation

/// A document's secret values as the Keychain holds them, by `SecretKey`: its files only ever say a variable is secret.
extension ProjectLibrary {
    static func secretValues(in document: ProjectDocument) -> [String: String] {
        secretValues(in: document.allEnvironments)
    }

    /// Every secret variable's value, keyed by `SecretKey`.
    static func secretValues(in environments: [RequestEnvironment]) -> [String: String] {
        var values: [String: String] = [:]
        for environment in environments {
            for variable in environment.variables where variable.isSecret {
                values[SecretKey.variable(variable.id, in: environment.id)] = variable.value
            }
        }
        return values
    }

    /// Sets each secret variable's value from `secrets`. One `secrets` lacks is blank, as when loading reads every value
    /// there is, or, `keepingMissing`, keeps the value it has, as when only some arrive.
    static func fillSecretValues(in document: inout ProjectDocument, from secrets: [String: String], keepingMissing: Bool) {
        for environment in document.allEnvironments {
            document.updateEnvironment(environment.id) { environment in
                for index in environment.variables.indices where environment.variables[index].isSecret {
                    let key = SecretKey.variable(environment.variables[index].id, in: environment.id)
                    if let value = secrets[key] {
                        environment.variables[index].value = value
                    } else if !keepingMissing {
                        environment.variables[index].value = ""
                    }
                }
            }
        }
    }
}
