import Foundation

/// What Reqling reads of the provisioning profile embedded in its bundle, which grants it iCloud.
public enum ProvisioningProfile {
    /// The running app's, beside its executable's folder, where `scripts/build.sh` embeds it.
    public static var embeddedURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
    }

    /// When the profile at `url` expires, or `nil` when there's none or it won't read. macOS stops opening a Developer ID
    /// build whose profile expired, so Settings warns ahead of it. The signed profile carries its property list as plain
    /// XML, so it's read without verifying the signature, which macOS does at launch.
    public static func expirationDate(of url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["ExpirationDate"] as? Date
    }
}
