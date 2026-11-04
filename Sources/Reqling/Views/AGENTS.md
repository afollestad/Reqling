## SwiftUI View Composition

These are view-layer defaults for files under `Sources/Reqling/Views/` unless a narrower `AGENTS.md` overrides them.

- In SwiftUI, prefer extracted `View` types over `some View` extension properties. Keep trivial one-off stacks inline, and only extract when it clarifies composition.
- When an extracted child view is used by another view, place it in the same folder with `<Parent>+<Child>.swift` naming.
- **Every icon-only interactive control needs `.help(...)` and an `.accessibilityLabel`** — plain glyph buttons, icon-labeled `Menu`s, and hover-only affordances included. Without visible text, the tooltip is the only discoverable name for sighted users and the label the only one for VoiceOver. Add both when creating the control.
- **Define every custom color for both light and dark appearances.** Use asset-catalog colors, semantic system colors, or an explicit per-`ColorScheme` palette; a single literal reads wrong in one of them.
- **Keep `body` off the compiler's type-check budget.** Swift solves an expression as a whole, so a long modifier chain resolves every generic overload in it together; past the wall-clock budget the compiler hard-errors with `unable to type-check this expression in reasonable time`.
    - **Lift modifier groups out of `body`.** Move each group — presentation modifiers (`sheet`, `alert`, `confirmationDialog`) and observers (`onChange`, `task`) are the usual offenders — into a `func …<Content: View>(_ content: Content) -> some View` helper, its own type-check scope, and keep chain order identical so modifier semantics do not shift.
    - **Measure, and read local numbers as a lower bound.** `TYPECHECK_BUDGET_MS=400 ./scripts/build.sh` lists every body over that many milliseconds; slower machines measure several times higher than a fast local one.

## Render Cost

- **Hoist every view-model read above a `GeometryReader`.** Its closure re-runs on each geometry change — every frame of a window or split-view resize — so a read left inside it repeats whatever shaping it triggers per frame. Pair the hoist with memoizing that shaping in the view model (`Sources/Reqling/ViewModels/AGENTS.md`).
- **Reset a search-driven scroll with `ScrollPosition`, never `.id(searchQuery)` on the scroll view.** Keying by the query rebuilds the whole subtree and discards lazy-stack state on every keystroke. Keying by a *discrete* selection, which changes once per click, is fine.
- **Give list rows and pane children an `Equatable` conformance that excludes their closures.** A parent that re-runs per frame otherwise rebuilds every row. Exclude a closure when its captures are reference types, `@State`/`@FocusState` storage, or values already compared — and say which in the `==` doc comment.
    - **Never compare a `@Binding` there.** A binding's projected read is main-actor computed, so a `nonisolated ==` reads across isolation and Swift 6 warns. Take the value as a plain `let` plus a `@MainActor` change closure, and rebuild the binding in `body`.

## Focus And Keyboard

- Attach modifier-key shortcuts with `.keyboardShortcut()` on buttons that stay in the window hierarchy, or register them from the scene with `.commands { CommandGroup(...) }`. Both dispatch through the responder chain and are focus-independent. Never bury a shortcut-bearing button in a conditionally rendered branch — the shortcut disappears with the branch.
- A non-modifier `.onKeyPress` on a new surface (arrow keys in a list, say) competes with whatever else claims focus. Publish a `FocusedSceneValue` for it and release focus explicitly on takeover, rather than writing another surface's `@FocusState`.
