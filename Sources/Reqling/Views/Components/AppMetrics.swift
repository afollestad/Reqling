import SwiftUI

/// The shared sizes surfaces are built from, so a field, an editor, and a pane read as one family. The settings
/// screen keeps its own card system in `SettingsScreenLayout`, which takes its inset from here.
enum AppMetrics {
    /// Text fields, code editors, and the sidebar filter.
    static let inputCornerRadius: CGFloat = 6
    /// Method pills and icon tiles.
    static let badgeCornerRadius: CGFloat = 4
    /// Banners and other free-standing containers.
    static let containerCornerRadius: CGFloat = 8
    /// The inset inside a pane: the request editor, the response, a sheet's body.
    static let paneInset: CGFloat = 16
    /// The inset of a full detail screen: a project, a folder, Settings.
    static let screenInset: CGFloat = 28
    /// `LabeledRow`'s label column, and the gap between it and the control.
    static let labelWidth: CGFloat = 96
    static let labelSpacing: CGFloat = 8
}
