import Foundation
import Security

/// Whether this process still matches its bundle on disk.
///
/// macOS refuses Keychain access, without showing its prompt, to a process whose app was rebuilt or replaced after it
/// launched (`errSecCSStaticCodeChanged`), and reports that only as a generic "user name or passphrase" failure. Checking
/// here lets the error say what fixes it: reopening the app.
enum RunningCodeSignature {
    static var hasChangedOnDisk: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], nil) == errSecCSStaticCodeChanged
    }
}
