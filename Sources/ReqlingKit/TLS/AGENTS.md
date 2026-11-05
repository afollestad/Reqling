## TLS

These instructions cover `Sources/ReqlingKit/TLS/`: client certificates (mutual TLS), extra CAs, and trust evaluation.

- **Never add identities or keys to a keychain, temporary ones included.** PEM pairs become identities only through `PEMIdentityImporter`'s in-memory PKCS#12; an import would leave the user's key material on disk.
- **Snapshot passphrases and Keychain references before execution** (`RequestRunner.tlsContext`). TLS challenges arrive off the main actor, so the HTTP delegate must never reach back into the library.
