# TLS and client certificates

A project's **Project Settings** hold its client certificates and extra CA certificates.

## Client certificates (mutual TLS)

- **Formats.** A PKCS#12 file (`.p12`/`.pfx`), a PEM certificate and private key (`.crt`/`.key`, RSA or EC, encrypted or not), or an identity already in your Keychain.
- **Matched by host**, such as `api.example.com`, `*.internal`, or `host:8443`.
- **Passphrases** are stored in your Keychain. Certificates and keys are read in memory and never added to it.

## CA certificates

- **Extra CAs** are trusted in addition to the system's.

## Known limitation

- **Explicit EC curves.** macOS can't open a certificate whose EC key uses explicit curve parameters instead of a named curve; Reqling reports this instead of crashing.
- **Fix.** Reissue the certificate from a named-curve key. Re-exporting the same certificate doesn't help.
