## Run History

These instructions cover `Sources/ReqlingKit/History/`: every request's past runs on this Mac. `RunHistoryStore.swift` documents the folder layout.

- **Record runs only through `RequestRunner.record`, and clear them only through `RequestRunner`** (`forget`, `clearHistory`, `moveHistory`). The runner keeps `latest` in step, so the window never shows a run its history has dropped.
- **Drop or carry history wherever requests leave a project.** Deleting items and moving them between projects go through `ProjectLifecycle` (`deleteNode`, `moveNode`), and switching protocol through `RequestRunner.forget`; a bare `removeNode` orphans runs.
- **Store only masked resolutions plus the template that ran**, never a resolved secret value; `Sources/ReqlingKit/Templating/AGENTS.md` owns masking.
- History is this Mac's record, not project content: it lives under Application Support and is removed directly, not trashed (`Sources/ReqlingKit/Storage/AGENTS.md`'s Trash rule covers project files).
