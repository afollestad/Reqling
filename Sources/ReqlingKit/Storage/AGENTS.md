## Project Storage

These instructions cover `Sources/ReqlingKit/Storage/`: the on-disk project format, the library, secrets, and per-Mac workspace state. `ProjectFiles.swift` documents the folder layout.

- **Edit projects only through `ProjectLibrary.mutate`, and Global only through `mutateGlobalEnvironment`.** Each stores new secrets, writes to disk, publishes, then deletes removed secrets, so memory always matches disk; the external-change reload compares content on that guarantee instead of tracking which writes were Reqling's own.
- **Keep stored row IDs when rebuilding a list.** Query rows, headers, form fields, and metadata merge by ID (`ListMerge`); code that rebuilds one from text or an agent's input gives surviving rows their old IDs (`ListRow`), or every edit reads as remove-plus-add.
- **Never write a secret value or an absolute path into a project file.** Secrets go to `SecretStore` (the Keychain), leaving only the key and `"secret": true`; machine-specific paths go to `WorkspaceStateStore` as `ProjectPathReference.local`.
- Keep per-user state (active environment, expansion, selection, run history, current values) out of project folders, so using the app never shows up in `git status`.
- **Write current values only through `CurrentValueStore`.** Saved-value edits drop them inside `mutate` and `mutateGlobalEnvironment` (`ProjectLibrary+CurrentValues.swift`); never drop them on `reload`, or a `git pull` would discard what scripts set.
- **Deletes go to the Trash** through `FileTrashing`, never `removeItem`.
- **Move, trash, and reserve a request's script files with its JSON** (`ProjectWriter+Scripts.swift`); any code that relocates a request file outside `ProjectWriter+Moves.swift` must carry them, or they orphan and reserve the slug.
- **Refuse to save a newer `formatVersion`.** Such a project opens read-only; rewriting it would drop fields this version does not understand. Bump `ProjectDocument.currentFormatVersion` only with a reader that still loads every older version.
