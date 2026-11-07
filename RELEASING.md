# Releasing Reqling

Reqling ships as a GitHub Release with a `Reqling.app.zip` asset containing an Apple silicon, Developer ID–signed, notarized `Reqling.app`, plus `Reqling.dSYMs.zip` for symbolicating crash reports from the app and its helpers. Running copies of Reqling find new releases through the in-app updater, which shows each release's notes.

## Versioning

The version lives in `Resources/Info.plist`:

- `CFBundleShortVersionString`: the `X.Y.Z` release version.
- `CFBundleVersion`: an integer build number that must increase with every release.

To release, bump both, commit as `Release Reqling vX.Y.Z`, and push to `main`. CI creates the tag; never push release tags yourself.

## Release Builds

`.github/workflows/release.yml` builds on every push to `main` and on manual runs. `scripts/ci/detect-release-version.py` picks the mode:

| Mode | Trigger | Notarizes | Result |
| --- | --- | --- | --- |
| `release` | Push to `main` when publishing is enabled and the current version has no `vX.Y.Z` tag on origin | Yes | Tag and GitHub Release |
| `canary` | Any other push to `main`, including one held back by the publish gate | No | Actions artifact holding `Reqling.app` |
| `dry-run` | Manual `workflow_dispatch` | Yes | Actions artifact holding `Reqling.app.zip` |

- With publishing enabled, a push publishes the current version whenever its tag is missing, which covers the first release and retrying a failed one.
- The tag is pushed only after signing, verification, notarization, stapling, packaging, and release-note generation succeed.
- Release notes are written by Copilot CLI from the commits since the previous release (or the whole history for the first one), limited to user-facing changes and grouped by theme.
- A newer canary cancels an unfinished one. Release and dry run builds are never cancelled.
- The release-only steps (previous tag, release notes, tag, GitHub Release) first run at the first publish; a dry run stops before them.

### Publish gate

Publishing is off until the `RELEASES_ENABLED` repository variable is `true`. While it is unset or anything else, a push that would release builds a canary instead and says so in a notice, though the version is still validated as a release. To publish:

```sh
gh variable set RELEASES_ENABLED --body true -R afollestad/Reqling
git commit --allow-empty -m "Release Reqling vX.Y.Z"   # or the commit that bumps Info.plist
git push origin main
```

Delete the variable (`gh variable delete RELEASES_ENABLED -R afollestad/Reqling`) to hold releases again.

### Failed releases

The tag is pushed just before `gh release create`. If that last step fails, the tag exists without a release, and a re-run would build a canary because the tag is taken. Delete the tag, then re-run the workflow:

```sh
git push --delete origin vX.Y.Z
gh run rerun <run-id> -R afollestad/Reqling
```

### Canaries and dry runs

Download a canary (signed but not notarized, so clear the quarantine):

```sh
gh run list --workflow Release --branch main --limit 5
gh run download <run-id> --repo afollestad/Reqling -D ~/Downloads
xattr -dr com.apple.quarantine ~/Downloads/Reqling-canary-*/Reqling.app
```

Rehearse a release without publishing: `gh workflow run Release --ref main`. Its artifact holds the notarized `Reqling.app.zip`.

Release builds run as `com.afollestad.reqling`, with your real projects, Keychain items, and MCP port, unlike the separate **Reqling Dev** identity of debug builds.

## Secrets

Set these repository secrets (Settings → Secrets and variables → Actions, or `gh secret set`). Never commit signing material. Every mode signs, so Release runs fail at `scripts/ci/check-secrets.sh`, which names whatever is missing, until the signing secrets exist; canaries skip the App Store Connect ones.

None of these values are app-specific, so other apps on the same team can use the same certificate and API key. GitHub never reveals stored secrets, though, so copy them from their sources rather than from another repository.

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character team ID, shown in parentheses after the name of the `Developer ID Application` identity that `security find-identity -v -p codesigning` lists |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application certificate and private key, exported as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | Any random string; CI uses it for its temporary keychain |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Base64 of an App Store Connect API key (`AuthKey_<KEY_ID>.p8`) used for notarization |
| `APP_STORE_CONNECT_KEY_ID` | That key's ID, the `<KEY_ID>` in its file name |
| `APP_STORE_CONNECT_ISSUER_ID` | The issuer ID shown above the App Store Connect API keys list |

### Developer ID certificate

1. Confirm `security find-identity -v -p codesigning` lists **Developer ID Application: …**. If not, create one in Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID Application.
2. Run `./scripts/set-certificate-secrets.sh` and approve macOS's keychain prompts with your login password. It exports only the Developer ID identity, in the `.p12` format CI's `security import` accepts (it rejects OpenSSL 3+'s default with "MAC verification failed"), with a random password. It then imports the file exactly as CI does and sets `MACOS_CERTIFICATE_P12_BASE64` and `MACOS_CERTIFICATE_PASSWORD`. Pass `--dry-run` to check without changing secrets.
3. Set the remaining signing secrets:

   ```sh
   openssl rand -hex 24 | gh secret set MACOS_KEYCHAIN_PASSWORD -R afollestad/Reqling
   gh secret set APPLE_TEAM_ID -R afollestad/Reqling   # prompts for the team ID
   ```

### Notarization API key

1. In App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys, generate a key with the **Developer** role (this needs the Account Holder or Admin role, and the first visit may ask you to request access). The `.p8` downloads only once.
2. Check the key, then upload it with its key ID and the issuer ID shown on that page:

   ```sh
   xcrun notarytool history --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   base64 -i AuthKey_<KEY_ID>.p8 | gh secret set APP_STORE_CONNECT_API_KEY_P8_BASE64 -R afollestad/Reqling
   gh secret set APP_STORE_CONNECT_KEY_ID -R afollestad/Reqling      # prompts for the key ID
   gh secret set APP_STORE_CONNECT_ISSUER_ID -R afollestad/Reqling   # prompts for the issuer ID
   ```

3. Store the `.p8` somewhere safe, such as a password manager, then delete the download. `.gitignore` excludes `*.p8`, but keep it out of the checkout anyway.
