## Script Runner

These instructions cover `Sources/ReqlingScriptRunner/`: the helper that runs pre-request, stream, and post-response scripts in JavaScriptCore, and its JavaScript runtime under `Runtime/`.

- **Use public JavaScriptCore API only.** Its only way to stop a script, `JSContextGroupSetExecutionTimeLimit`, is SPI; the app kills this process at the time limit instead (`HelperScriptRunner`), so nothing here bounds time.
- **Touch JavaScriptCore and `EventWriter` only on the main thread.** Every phase reads its input after the bodies on a thread of its own, which only queues items and fetch replies (`ScriptInbox`); neither has a lock.
- **Report as things happen.** Write each event the moment it occurs (`EventWriter`), never batched at the end: values a script sets before it throws or is killed must still reach the app.
- **Expose the runtime to scripts only through `rq`, `pm`, and the globals `ScriptAPICatalog` documents.** `Sources/ReqlingKit/Scripting/AGENTS.md` owns keeping the catalog and `Runtime/` in step.
- **Load vendored libraries only by fixed name** (`ScriptRuntimeFiles.libraries`), so `require` can never read another file. Updating one means replacing its file and license from the npm tarball, checking the tarball against npm's published integrity, and updating `Runtime/vendor/manifest.json`, whose hashes a test checks.
- `Runtime/` is not a SwiftPM resource: `scripts/build.sh` copies it into `Contents/Resources/ScriptRuntime`, and tests read it from the repository (`Tests/ReqlingKitTests/Support/ScriptFixtures.swift`).
