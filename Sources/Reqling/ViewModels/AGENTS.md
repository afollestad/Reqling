## View Models

These instructions apply to files under `Sources/Reqling/ViewModels/`.

- View models are `@MainActor @Observable` classes; never use `ObservableObject`. Mark injected dependencies and caches `@ObservationIgnored`.
- **Keep view models as coordination layers.** Route UI intent, own observers and watchers, and delegate service-backed state to focused `ReqlingKit` collaborators when it becomes shared or long-running.
- **Own side effects.** View models own mutable runtime state, persistence calls, and side effects; views never call services directly.
- **Keep presentation derived.** Renderer-neutral `*Presentation` types may derive display and action values from view-model state but never replace view-model ownership or perform mutations.
- **Do not let a root view index an observable dictionary.** `@Observable` has no per-key granularity, so reading one entry makes every write to any entry re-render that view. Mirror what the root needs onto its own property, refreshed from every mutation in the file that owns the dictionary's setter.
- **Memoize list shaping behind an `@ObservationIgnored` cache**, keyed on every input it reads. The getter **must still read every observable input to build the key before consulting the cache**, or `@Observable` stops tracking the dependency and the view goes stale. Screens that render this pay for it per geometry frame — see **Render Cost** in `Sources/Reqling/Views/AGENTS.md`.
- **Shape response bodies through `ResponseBodyShaper`, started from a view's `.task(id:)`, never from a getter.** A multi-megabyte body takes seconds to shape, and work a getter starts re-runs or blocks on every render.
- **Read a response pane's exchange through `RunHistoryViewModel.shownExchange`, never `RequestRunner.latest`**, or a run picked in the history inspector never shows.
- **Get a gRPC request's schema only through `RequestRunner.grpcSchema(for:in:options:)`.** It resolves the target, auth, and TLS exactly as a run does, so the editor's service and method pickers always describe what Send will call.
