import Foundation

extension URL {
    /// This file URL's path with the home folder shortened to `~`, for showing people. Display only: file APIs do
    /// not expand `~`. `~` means the real home folder only while the app is unsandboxed; a sandbox would shorten
    /// its container instead.
    public var abbreviatedPath: String {
        (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}
