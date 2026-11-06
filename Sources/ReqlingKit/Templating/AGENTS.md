## Templating

These instructions cover `Sources/ReqlingKit/Templating/`: run scopes and resolution over the shared core in `Sources/ReqlingTemplating/AGENTS.md`.

- **Resolve with `masked: true` for anything displayed, stored, or handed to an agent** (previews, summaries, the run history), so secret values never leave the request that needs them. Copy as cURL is the deliberate exception: the user copies it to run it.
- Build every run's scope through `VariableScope`'s environment initializer rather than assembling entries by hand; the order itself lives in `VariableLayers`.
