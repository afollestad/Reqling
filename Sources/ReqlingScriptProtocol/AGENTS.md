## Script Runner Protocol

These instructions cover `Sources/ReqlingScriptProtocol/`: what the app and `ReqlingScriptRunner` exchange — the input, the events, framing, exit statuses, and limits — and the cookie and URL rules both sides share.

- **Keep this target Foundation-only, depending on nothing but `ReqlingTemplating`.** The runner links it, and each launch must stay fast.
- **Bump `ScriptRunnerInput.currentProtocolVersion` on any change one side could misread.** The helper ships inside the app, but a stale build in `.build/` or a test bundle can pair either side with the other's old version.
- **Read and write both directions only through `ScriptFraming`.** Never switch to newline-delimited JSON: U+2028 in a `console.log` would split a line.
- **Parse, match, and validate cookies only through `ScriptCookieScope` and `ScriptCookieSetting`, and match a URL only through `HTTPCookieStorage.cookies(for:)`,** in the helper, `ProjectCookieJar`, and MCP alike, so scripts, agents, and what URLSession sends never disagree.
