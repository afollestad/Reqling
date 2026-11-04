import ReqlingKit

/// The app's long-lived services. Production storage uses the Keychain, the Trash, and folder watching; an ephemeral
/// (test) profile swaps in in-memory secrets, a directory trash, and no watching, so a test graph can never touch the
/// developer's real data.
@MainActor
extension AppComponent {
    var secretStore: any SecretStore {
        shared {
            if storageProfile.isEphemeral {
                return InMemorySecretStore() as any SecretStore
            }
            return KeychainSecretStore(service: "\(appInfo.bundleIdentifier).secrets")
        }
    }

    var trasher: any FileTrashing {
        shared {
            if storageProfile.isEphemeral {
                return DirectoryTrash(directory: storageProfile.trashDirectory) as any FileTrashing
            }
            return SystemTrash()
        }
    }

    var keychainIdentities: any KeychainIdentityStore {
        shared {
            if storageProfile.isEphemeral {
                return EmptyKeychainIdentityStore() as any KeychainIdentityStore
            }
            return SystemKeychainIdentityStore()
        }
    }

    var projectLibrary: ProjectLibrary {
        shared {
            ProjectLibrary(configuration: .init(
                registryURL: storageProfile.registryURL,
                defaultProjectsDirectory: storageProfile.projectsDirectory,
                secretStore: secretStore,
                trasher: trasher,
                monitorFactory: storageProfile.isEphemeral ? nil : FSEventsProjectMonitor.factory
            ))
        }
    }

    var workspaceState: WorkspaceStateStore {
        shared { WorkspaceStateStore(fileURL: storageProfile.workspaceStateURL) }
    }

    var settingsStore: SettingsStore {
        shared { SettingsStore(defaults: storageProfile.settingsDefaults) }
    }

    var requestRunner: RequestRunner {
        shared {
            RequestRunner(
                library: projectLibrary,
                workspace: workspaceState,
                settings: settingsStore,
                keychain: keychainIdentities,
                cache: ResponseCache(directory: storageProfile.responsesDirectory),
                userAgent: appInfo.userAgent,
                grpcSchemas: grpcSchema
            )
        }
    }

    var appModel: AppModel {
        shared {
            AppModel(
                library: projectLibrary,
                workspace: workspaceState,
                runner: requestRunner,
                settings: settingsStore,
                appInfo: appInfo,
                keychain: keychainIdentities,
                system: systemIntegration,
                protoWorkspaces: protoWorkspaces,
                protocTooling: protocTooling
            )
        }
    }
}
