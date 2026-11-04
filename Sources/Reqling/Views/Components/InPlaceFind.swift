import AppKit
import SwiftUI

/// A view that searches its own content when Find… (⌘F), Find Next (⌘G), or Find Previous (⇧⌘G) reaches it.
@MainActor
protocol InPlaceFindTarget: AnyObject {
    func performFind(_ action: NSTextFinder.Action)
}

/// Routes the Find menu to whatever searches in place where focus is.
@MainActor
enum InPlaceFind {
    /// Sends `action` to the nearest `InPlaceFindTarget` up the responder chain from `window`'s first responder,
    /// returning false when there is none.
    static func perform(_ action: NSTextFinder.Action, in window: NSWindow?) -> Bool {
        var responder = window?.firstResponder
        while let current = responder {
            if let target = current as? InPlaceFindTarget {
                target.performFind(action)
                return true
            }
            responder = current.nextResponder
        }
        return false
    }
}

extension FocusedValues {
    /// The search a focused `BodySearchBar` drives, so the Find menu reaches it while its field has focus; the field
    /// edits through AppKit's field editor, which is outside the searched view's responder chain.
    @Entry var bodySearch: BodySearchModel?
}
