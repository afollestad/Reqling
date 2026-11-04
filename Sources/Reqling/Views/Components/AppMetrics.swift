import SwiftUI

/// The shared sizes surfaces are built from, so a field, an editor, and a pane read as one family. The settings
/// screen keeps its own card system in `SettingsScreenLayout`, which takes its inset from here.
enum AppMetrics {
    /// Text fields, code editors, and the sidebar filter.
    static let inputCornerRadius: CGFloat = 6
    /// Method pills and icon tiles.
    static let badgeCornerRadius: CGFloat = 4
    /// The square tile of an icon-only button (`IconButtonStyle`).
    static let iconButtonSize: CGFloat = 22
    /// The glyph inside that tile, a point under body text: at 13pt, `doc.on.doc` nearly fills the tile. A label that
    /// sets its own font, like Settings' bold close glyph, keeps it.
    static let iconButtonGlyphSize: CGFloat = 12
    /// Banners and other free-standing containers.
    static let containerCornerRadius: CGFloat = 8
    /// The inset inside a pane: a sheet's body, and the top and bottom of the request and response panes.
    static let paneInset: CGFloat = 16
    /// The horizontal inset of the request and response panes, which sit under the window title: macOS draws the title
    /// this far from the detail column's edge, and offers no way to move it, so the panes match it instead.
    static let detailPaneInset: CGFloat = 20
    /// The gap between an editor's section tabs and the section below them.
    static let sectionTabsSpacing: CGFloat = 18
    /// The inset of a full detail screen: a project, a folder, Settings.
    static let screenInset: CGFloat = 28
    /// `LabeledRow`'s label column, and the gap between it and the control.
    static let labelWidth: CGFloat = 96
    static let labelSpacing: CGFloat = 8
}
