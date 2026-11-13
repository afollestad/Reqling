## App Lifecycle And Root Layout

These instructions cover `Sources/Reqling/App/` — the entry point, the root `ContentView`, and window scaffolding.

- Keep `NSApplicationDelegate` implementations on `@MainActor`.
- When Swift 6 strict concurrency and AppKit interop fight in lifecycle code, prefer small explicit seams: injected dependencies for startup and shutdown behavior, and `@preconcurrency import AppKit` only where needed to bridge sendability gaps.
- **Finish shutdown work synchronously.** Teardown that must complete before exit (pending autosaves, file watchers, listeners) runs on the main actor inside `applicationWillTerminate`, never behind a `Task` hop the process can outlive.
- **To reach the main actor from a callback not guaranteed to run there**, use `Task { @MainActor in ... }` — never `DispatchQueue.main.async` plus `MainActor.assumeIsolated`. `assumeIsolated` stays right inside callbacks already delivered on main.
- **Keep root view `init`s free of observable reads, constructors included.** A read there re-runs the whole root on every later write to that value; build root view models before the view, from the DI component.
- **Keep the window toolbar's background hidden** (`ContentView`); over a pane without a scroll view, macOS otherwise draws an opaque band that mismatches the content. Never paint the toolbar a color instead: the window background follows the desktop tint.
- **The visible window title is `DetailTitleBar`, a `.navigation` toolbar item.** Remove only the system title's rendering (`.toolbar(removing: .title)`), never set an empty `navigationTitle`: the scene's title names the window to VoiceOver and the Window menu.
- **List every trailing detail toolbar item in `MainToolbarItemID.trailingItems`.** `WindowToolbarConfigurator` inserts the flexible space before the first one present; an unlisted item placed ahead of them packs against the title.
- **Give a toolbar `Menu` with a multi-line label `.menuStyle(.button)`, its own `ButtonStyle`, and one combined accessibility element,** as `EnvironmentPicker` does. The system style keeps only the label's first line; uncombined, each part of the label reads as a separate button.
- Resolve services from `AppDI.component` only at the app entry point and pass them down; views and view models that reach for the singleton cannot be tested against isolated storage.
