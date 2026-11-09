## iCloud Sync

These instructions cover `Sources/ReqlingKit/Sync/`: the records, the merge, what sync keeps on this Mac, and the coordinator (`LibrarySync`) behind its transport.

- **Put every record field in `encryptedValues`, under a fixed name.** Field names are plaintext schema that Production can never lose, so never derive one from a variable, key, or ID.
- **Bump `ProjectRecordCoder.schemaVersion` whenever a synced model gains or renames an encoded key,** with `SyncRecordCoderTests.testThePayloadSchemaMatchesItsVersion`; an older Mac then holds the project back instead of stripping the field.
- **Keep no secret value or plaintext content under the sync directory.** Bases are `SyncDigester` digests, and server records are kept only as their opaque system fields.
- **Never send a secret as blank.** A Keychain that can't be read sends no secrets, and a value this Mac lacks is left out (`ProjectRecordCoder.records(for:secrets:)`, `LibrarySync.localRecords(in:)`).
- **Never infer a deletion from something missing.** Deletions go out only for a project read without issues, and a zone deletion trashes a project only with its tombstone (`LibrarySync.finishFetching`).
- **Apply another Mac's changes only through the library's sync entry points** (`Sources/ReqlingKit/Storage/AGENTS.md`), never `mutate`, which would send them back.
- **Never log a record, payload, or secret;** interpolate anything else as `.private`, and describe transport errors in fixed text.
