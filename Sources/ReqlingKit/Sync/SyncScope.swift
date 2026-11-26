import Foundation
import Security

/// Which projects sync: those directly in Reqling's own projects folder, which only Reqling writes. A project in a git
/// repository has git to share it, and two writers in one working tree would fight, so one inside a repository, a
/// symlink to one, or anything elsewhere stays out.
enum SyncScope {
    static func contains(_ project: URL, projectsDirectory: URL) -> Bool {
        let values = try? project.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink == false, values?.isDirectory == true else {
            return false
        }
        // Identifiers rather than paths, which no one normalizes: case, `/private`, and trailing slashes all differ.
        guard let parent = identifier(of: project.deletingLastPathComponent()),
              let projects = identifier(of: projectsDirectory),
              parent.isEqual(projects) else {
            return false
        }
        return !ProjectPathResolver.isInsideRepository(project)
    }

    private static func identifier(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? any NSObjectProtocol
    }
}

/// Whether this build can use iCloud at all. `CKContainer` traps in a process without the iCloud container
/// entitlement (ad hoc builds, the test bundle), so this is checked before CloudKit is touched.
public enum SyncAvailability {
    /// `iCloud.com.afollestad.reqling`, or in a debug build, the container its `Info.plist` names instead: the sharing
    /// harness's build (`scripts/sharing-e2e.sh`) names one of its own, so its runs never reach the app's data.
    public static let containerIdentifier: String = {
        #if DEBUG
        if let harness = Bundle.main.object(forInfoDictionaryKey: "ReqlingCloudKitContainer") as? String {
            return harness
        }
        #endif
        return appContainerIdentifier
    }()

    /// The app's own container, holding people's real data, which the sharing harness never runs in (`SharingHarness`).
    static let appContainerIdentifier = "iCloud.com.afollestad.reqling"

    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else {
            return false
        }
        return containers.contains(containerIdentifier)
    }
}
