import Foundation
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

    /// The helper sits beside the app's executable, where `scripts/build.sh` copies it. Test graphs get none, so their
    /// PKCS#12 checks fail closed instead of launching anything.
    var pkcs12ImportProbe: any PKCS12ImportProbe {
        shared {
            let helper = storageProfile.isEphemeral ? nil : Bundle.main.url(forAuxiliaryExecutable: "ReqlingPKCS12Probe")
            return HelperPKCS12ImportProbe(executable: helper) as any PKCS12ImportProbe
        }
    }

    var projectLibrary: ProjectLibrary {
        shared {
            ProjectLibrary(configuration: .init(
                registryURL: storageProfile.registryURL,
                defaultProjectsDirectory: storageProfile.projectsDirectory,
                globalEnvironmentURL: storageProfile.globalEnvironmentURL,
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

    var runHistory: RunHistory {
        shared { RunHistory(directory: storageProfile.historyDirectory, settings: settingsStore) }
    }

    var requestRunner: RequestRunner {
        shared {
            RequestRunner(
                library: projectLibrary,
                workspace: workspaceState,
                settings: settingsStore,
                keychain: keychainIdentities,
                pkcs12Probe: pkcs12ImportProbe,
                history: runHistory,
                userAgent: appInfo.userAgent,
                grpcSchemas: grpcSchema,
                graphQLSchemas: graphQLSchemas
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
                pkcs12Probe: pkcs12ImportProbe,
                system: systemIntegration,
                protoWorkspaces: protoWorkspaces,
                protocTooling: protocTooling,
                mcpServer: mcpServer,
                updates: appUpdates
            )
        }
    }
}
