## Templating

These instructions cover `Sources/ReqlingKit/Templating/`: `{{variable}}` parsing, scopes, and resolution.

- **`TemplateParser` is the single source of token ranges** for both resolution and the editor's pill drawing, so what is highlighted is exactly what will be substituted. Never add a second tokenizer for display.
- **Resolve with `masked: true` for anything displayed, stored, or handed to an agent** (previews, summaries, the run history), so secret values never leave the request that needs them. Copy as cURL is the deliberate exception: the user copies it to run it.
- Scope precedence is one-run overrides, then the active environment, then Default, then Global (`VariableScope`); keep every caller on that initializer rather than assembling scopes by hand.
