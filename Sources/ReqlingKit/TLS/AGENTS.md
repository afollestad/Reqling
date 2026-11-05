## TLS

These instructions cover `Sources/ReqlingKit/TLS/`: client certificates (mutual TLS), extra CAs, and trust evaluation.

- **Never add identities or keys to a keychain, temporary ones included.** PEM pairs become identities only through `PEMIdentityImporter`'s in-memory PKCS#12; an import would leave the user's key material on disk.
- **Call `SecPKCS12Import` only inside `PKCS12Importer`.** It raises an uncatchable exception when Security can't read the identity certificate's key, so files from disk pass `PKCS12ImportProbe` first; only `PEMIdentityImporter`'s in-memory PKCS#12 skips it.
- **Keep the helper's input and exit statuses in step** between `Sources/ReqlingPKCS12Probe/PKCS12Probe.swift` and `HelperPKCS12ImportProbe` (`PKCS12ImportProbe.swift`).
- **Snapshot passphrases and Keychain references before execution** (`RequestRunner.tlsContext`). TLS challenges arrive off the main actor, so the HTTP delegate must never reach back into the library.
