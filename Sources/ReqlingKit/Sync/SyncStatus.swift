import Foundation

/// Where iCloud sync stands, for Settings.
public enum SyncStatus: Equatable, Sendable {
    /// This build has no iCloud entitlement (ad hoc builds, tests).
    case unavailable
    case off
    case signedOut
    case syncing
    case upToDate(Date)
    /// Paused: a different iCloud account is signed in than this Mac's projects last synced with.
    case accountChanged
    /// Paused: another Mac deleted several projects at once, and these wait for a confirmation.
    case confirmingDeletions([ProjectID])
    /// Turned off because Reqling's iCloud data was deleted or reset; turning sync on again uploads this Mac's copy.
    case stopped(SyncStopReason)
    case failed(String)
}

public enum SyncStopReason: Equatable, Sendable {
    /// Deleted in System Settings.
    case dataDeleted
    /// The account's end-to-end encrypted data was reset.
    case encryptionReset
}

/// Which projects a coordinator syncs: this account's own, with Global and every project's personal values, over the
/// private database; or, in the coordinator it owns (`LibrarySync.sharedSync`), those other people share with it, over
/// the shared database (`LibrarySync+Sharing.swift`).
enum SyncRole {
    case own
    case shared
}
