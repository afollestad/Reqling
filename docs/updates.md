# Updates

Reqling updates itself from this repository's GitHub Releases.

- **When.** It checks when it opens and every 6 hours. Turn that off in **Settings ▸ App Updates**.
- **Toolbar.** The gear shows a dot when an update is available, and a green one once it's downloaded.
- **Verification.** Downloads are checked against GitHub's SHA-256 digest, then for the same bundle identifier, a newer version, a valid signature from the same developer, and Gatekeeper approval, before **Install & Relaunch** replaces the app.
- **Rollback.** A failed install restores the previous version.
- **Builds run from `.build/`** can check for updates but not install them.
