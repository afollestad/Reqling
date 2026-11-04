## TLS

These instructions cover `Sources/ReqlingKit/TLS/`: client certificates (mutual TLS), extra CAs, and trust evaluation.

- **Do not add loose PEM certificate and key support.** macOS has no public API that builds a `SecIdentity` from them without a keychain import, and Reqling never adds identities to a keychain; point users at `PKCS12Importer.conversionHint`.
- **Snapshot passphrases and Keychain references before execution** (`RequestRunner.tlsContext`). TLS challenges arrive off the main actor, so the HTTP delegate must never reach back into the library.
