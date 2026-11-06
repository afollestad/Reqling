## Templating Core

These instructions cover `Sources/ReqlingTemplating/`: `{{variable}}` tokenizing, expansion, and the precedence of variable layers. ReqlingKit's `Sources/ReqlingKit/Templating/` builds run scopes on top of it.

- **Keep this target Foundation-only, with no dependencies,** so helper executables can link it and still launch fast.
- **`TemplateParser` is the single source of token ranges** for both resolution and the editor's pill drawing, so what is highlighted is exactly what will be substituted. Never add a second tokenizer for display.
- **Precedence lives only in `VariableLayers`.** Everything that reads a run's variables flattens or queries it; never re-implement the order elsewhere.
