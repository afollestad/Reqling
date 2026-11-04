## Project Storage

These instructions cover `Sources/ReqlingKit/Storage/`: the on-disk project format, the library, secrets, and per-Mac workspace state. `ProjectFiles.swift` documents the folder layout.

- **Edit projects only through `ProjectLibrary.mutate`.** It stores new secrets, saves the folder, publishes, then deletes removed secrets, so memory always matches disk; the external-change reload compares content on that guarantee instead of tracking which writes were Reqling's own.
- **Never write a secret value or an absolute path into a project file.** Secrets go to `SecretStore` (the Keychain), leaving only the key and `"secret": true`; machine-specific paths go to `WorkspaceStateStore` as `ProjectPathReference.local`.
- Keep per-user state (active environment, expansion, selection, last responses) out of project folders, so using the app never shows up in `git status`.
- **Deletes go to the Trash** through `FileTrashing`, never `removeItem`.
- **Refuse to save a newer `formatVersion`.** Such a project opens read-only; rewriting it would drop fields this version does not understand. Bump `ProjectDocument.currentFormatVersion` only with a reader that still loads every older version.
