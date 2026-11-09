import Foundation

/// Sync through this Mac's iCloud account, and the copy of everything taken before an account first syncs here.
extension LibrarySync {
    /// Syncs through the signed-in iCloud account, or `nil` in a build that can't use iCloud (`SyncAvailability`), such
    /// as an ad hoc one, where `CKContainer` would trap.
    public static func iCloud(
        library: ProjectLibrary,
        lifecycle: ProjectLifecycle,
        secretStore: any SecretStore,
        directory: URL
    ) -> LibrarySync? {
        guard SyncAvailability.isEntitled else {
            return nil
        }
        return LibrarySync(
            library: library,
            lifecycle: lifecycle,
            secretStore: secretStore,
            directory: directory,
            transport: CloudKitSyncTransport()
        )
    }

    /// The copy the last account to sync here took before its first sync, for Show Backup in Finder; `nil` when there's
    /// none.
    public var backupDirectory: URL? {
        guard let folder = lastAccountFolder() else {
            return nil
        }
        let backup = directory.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(SyncBaseStore.backupFolderName, isDirectory: true)
        return FileManager.default.fileExists(atPath: backup.path) ? backup : nil
    }

    /// Backs up what's here before an account's first sync on this Mac sends or applies anything, and says so when
    /// `announcing`. The account's state is written at once, so a quit before the sync finishes can't make the next
    /// launch take what it half merged as the copy from before.
    func beginFirstSync(in store: SyncBaseStore, announcing: Bool) {
        backUp(into: store.directory.appendingPathComponent(SyncBaseStore.backupFolderName, isDirectory: true))
        store.update { $0.backedUp = true }
        store.save()
        if announcing {
            onFirstSync?()
        }
    }

    /// Copies Reqling's own projects folder, Global, and current values into `folder`, replacing an older copy, before
    /// an account's first sync here merges anything into them: a safety net should a merge go wrong. None of them holds
    /// a secret value, which stays in the Keychain. Best effort, since sync shouldn't wait on a copy that can't be made.
    func backUp(into folder: URL) {
        let files = FileManager.default
        try? files.removeItem(at: folder)
        guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return
        }
        let sources = [projectsDirectory, library.configuration.globalEnvironmentURL, library.configuration.currentValuesURL]
        for source in sources where files.fileExists(atPath: source.path) {
            try? files.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
    }
}
