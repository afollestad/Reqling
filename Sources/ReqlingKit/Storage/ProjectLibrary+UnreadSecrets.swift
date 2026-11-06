import Foundation

/// Secret values loading could not read, because the Keychain was locked or refused access, load blank alongside an
/// issue saying so. These read them again once something needs them, so unlocking the Keychain later needs no relaunch.
/// Only values still blank are filled: anything set since loading is newer than what the Keychain holds.
extension ProjectLibrary {
    /// Reads the project's and Global's unread secret values again, as a run or the Environments sheet needs them.
    /// Runs call this before resolving or masking anything, so a secret a server echoes back is masked too.
    public func reloadSecretsIfUnread(for project: ProjectID) {
        reloadGlobalSecretsIfUnread()
        reloadProjectSecretsIfUnread(project)
    }

    static func fillBlankSecrets(in environment: inout RequestEnvironment, from secrets: [String: String]) {
        for index in environment.variables.indices where environment.variables[index].isSecret && environment.variables[index].value.isEmpty {
            environment.variables[index].value = secrets[SecretKey.variable(environment.variables[index].id, in: environment.id)] ?? ""
        }
    }
}
