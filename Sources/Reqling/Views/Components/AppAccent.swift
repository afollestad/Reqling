import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The accent views draw with. In the app it is the system control accent: Reqling's purple, which the bundle
    /// names through `NSAccentColorName`, unless the user chose another in System Settings, which then wins.
    ///
    /// Read this rather than `Color.accentColor` or `NSColor.controlAccentColor`, which ignore it: tests run in
    /// `xctest`, a process without Reqling's bundle, where those fall back to the system blue. `appAccent(_:)` is how a
    /// test pins the real accent instead.
    @Entry var appAccent: NSColor = .controlAccentColor
}

extension View {
    /// Sets `appAccent` and the tint controls draw with together, so the two never disagree.
    func appAccent(_ color: NSColor) -> some View {
        environment(\.appAccent, color).tint(Color(nsColor: color))
    }
}
