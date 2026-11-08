# Scripts

JavaScript that runs before a request is sent, as an event stream, WebSocket, or gRPC call delivers each event or message, and after its response comes back, for HTTP, GraphQL, gRPC, and WebSocket requests alike. Use scripts to compute a signature or timestamp, to save a token from a login's response for the requests after it, to refresh an expired token before the request that needs it, to test what came back, and to answer a server's messages.

## Where scripts live

- **Requests.** A request's **Scripts** tab holds its **Pre-request**, **Stream**, and **Post-response** scripts.
- **Folders and the project.** Select a folder or the project to edit scripts that run for every request inside it.
- **Files.** Each script is a `.js` file beside its owner's JSON, such as `list-users.pre.js`, `list-users.stream.js`, `_folder.post.js`, or `project.pre.js`, so scripts travel with the project through git. An empty script has no file.
- **Badges.** The sidebar marks requests and folders that have scripts of their own.

## Order

In each phase, the project's script runs first, then each folder's from the outermost in, then the request's own. Each event or message goes through the stream scripts' handlers in that order too. Each script runs on its own, so a function or global one defines isn't there for the next; share values through variables.

- **Runs after** lists the scripts that run before the one you're editing. Click one to open it.
- **Run inherited scripts**, turned off on a request, runs only that request's own scripts. Turned off on a folder, it stops the scripts above that folder for every request inside it.

## When scripts run

- **Pre-request** scripts run before the request is resolved, so they can set the variables and headers it uses. If one throws or runs past its time limit, the request isn't sent.
- **Stream** scripts run when an event stream opens, a WebSocket connects, or a gRPC call's server first answers, and their handlers take each event or message as it arrives ([Stream scripts](#stream-scripts)). A response that isn't an event stream runs none.
- **Post-response** scripts run once the response arrives, or once an event stream, gRPC call, or WebSocket connection ends, including when you stop it, after the stream scripts' handlers finish. A request that gets no response, such as one that can't connect, runs none.
- **Previews.** Copy as cURL, GraphQL introspection, and gRPC reflection run pre-request scripts too, so they send what a run would. Nothing those scripts set is kept, cookies included, and a cached schema runs none.

## Writing scripts

Scripts are JavaScript, with top-level `await`. Reqling's API is `rq`:

```js
// Pre-request: send a timestamp with every request.
rq.request.headers.upsert("X-Request-Time", new Date().toISOString())

// Pre-request: sign the request with an HMAC.
const timestamp = Date.now().toString()
rq.request.headers.upsert("X-Timestamp", timestamp)
rq.request.headers.upsert("X-Signature", rq.crypto.hmac("sha256", rq.environment.get("apiSecret"), timestamp))

// Post-response, on a login: save its token for the requests after it, which send {{token}}.
rq.environment.set("token", rq.response.json().token, { secret: true })

// Post-response: test what came back.
rq.test("returns the user", () => {
  rq.expect(rq.response.code).to.equal(200)
  rq.expect(rq.response.json().name).to.be.a("string")
})
```

`{{name}}` inside a script is plain text. Read a variable with `rq.variables.get("name")`, or resolve text the way a request does with `rq.variables.replaceIn("{{baseUrl}}/users")`.

## Stream scripts

A stream script's top level registers handlers, which then take each event or message as it arrives:

```js
// Stream, on an event stream: test each event.
rq.onEvent((event) => {
  rq.test("is JSON", () => event.json())
})

// Stream, on a WebSocket: answer each ping, and keep the newest token.
rq.onMessage((message) => {
  const data = message.json()
  if (data.type === "ping") rq.send({ type: "pong" })
  if (data.token) rq.environment.set("token", data.token, { secret: true })
})
```

- **Handlers.** `rq.onEvent` takes an event stream's events, and `rq.onMessage` the messages a WebSocket or gRPC call receives, not those it sends or its pings. Register them while the script's top level runs. A handler for the other kind of stream never runs, so one folder script can serve every kind of request.
- **One at a time.** Each event goes through every handler before the next starts, and a handler's promise is awaited. A handler that throws is reported and still gets the events after. Timers a handler doesn't await are dropped when it finishes.
- **What the stream opened with.** `rq.response` holds an event stream's status and headers, a WebSocket handshake's code, headers, and subprotocol, or a gRPC call's metadata. The rest is known only once the stream ends, to post-response scripts.
- **Replies.** `rq.send(message)` sends on an open WebSocket, or on a gRPC call's open request stream: text as it is, an `ArrayBuffer` or typed array as a binary WebSocket message, and anything else as JSON. `{{name}}` in it is plain text, and a secret in it is masked on the timeline. It throws once the connection or request stream has closed.
- **Keeping up.** The stream never waits for its handlers. When they fall far behind, the oldest events waiting for them are dropped, and the Tests tab counts them.
- **Stop.** Stopping the stream, or a limit it reaches, lets the handlers finish the event in hand; those still waiting reach no handler. Stop again to stop the handlers too.
- **Reconnects.** An event stream that reconnects keeps its handlers, and `rq.response` stays what it first opened with.

## Variables

- **`rq.environment`** is the active environment, **`rq.defaultEnvironment`** the project's Default, and **`rq.globals`** Global. A value set through them is kept on this Mac as a [current value](projects.md#current-values), which overrides the saved one and never goes into the project.
- **`rq.variables`** reads every variable as `{{name}}` resolves it. A value set through it lasts only for the run, and beats every environment's.
- **Secrets.** Scripts can read secret values. A value set with `{ secret: true }`, under a secret variable's name, or containing another secret is masked wherever it shows, and an environment's or Global's is kept in the Keychain.
- **Partial runs.** Values a script sets before it throws or is stopped are kept.
- **While a stream is open,** a value a handler sets is kept within moments, for the handlers after it, for other requests, and for messages you send while connected, which resolve `{{name}}` with it.
- **Folder and project runs** carry `rq.variables` values from one request to the next within an iteration, and give scripts `rq.info.iteration` and a data file's row as `rq.iterationData` ([Running folders and projects](running-folders.md)).

## Cookies

Each project has its own cookie jar, which its HTTP requests, GraphQL introspection, and WebSocket handshakes share. It lives in memory until Reqling quits. Scripts read and change it through `rq.cookies`:

```js
// Post-response, on a login: test the session cookie the server set.
rq.test("logged in", () => rq.expect(rq.cookies.get("session")).to.be.a("string"))

// Pre-request: send a CSRF cookie with this request and every request after it.
rq.cookies.set("csrf", rq.environment.get("csrfToken"), { secure: true })

// Another URL, or every cookie of a domain.
rq.cookies.for("https://auth.example.com/login").remove("sid")
rq.cookies.for("example.com").clear()
```

- **Which cookies.** `rq.cookies` holds the cookies that go to the request's URL as it's sent, `{{variables}}` resolved. `rq.cookies.for(target)` takes another URL, or a bare domain such as `example.com` for every cookie of that host and its parent domains, whatever their path or `Secure` flag. `localhost:8080` and `example.com/api` are URLs.
- **When changes land.** A pre-request script's changes go out with the request, and a post-response script finds the response's `Set-Cookie`s already stored. Every change stays for the requests after it, including those made before a script throws or is stopped.
- **Setting.** `set(name, value)` makes a cookie for path `/` and the URL's host alone, lasting until Reqling quits. Options change that: `path`, `domain` (the host or a parent domain, so its subdomains get the cookie too), `expires` (a Date, a date string, or milliseconds; one already past removes the cookie, and one more than 400 days out is cut to 400 days, as browsers do), `secure`, `httpOnly`, and `sameSite`.
- **Removing.** `remove(name)` and `clear()` act on what their scope covers. On a bare domain, that includes cookies set for its parent domains, which sibling hosts share.
- **gRPC** calls go to no URL, so their scripts reach the jar only through `rq.cookies.for(…)`.
- **A typed `Cookie` header** stands in for the jar on that request: the jar's cookies don't go with it, and its response's `Set-Cookie`s aren't stored, so read those from `rq.response.headers`. A script's changes still land in the jar for the requests after it.
- **Previews** keep no cookie a script sets, so GraphQL introspection sends the jar as it was.
- **Requests scripts send** carry the cookies the scripts set, and `rq.cookies` reads what their responses stored ([Sending requests](#sending-requests)).
- **Postman.** `pm.cookies` reads the request's cookies, and `pm.cookies.jar()` reaches any URL's; its callbacks run before the call returns.
- **History** lists which cookies scripts set or removed, never their values. A cookie's value that a script prints isn't masked.

## Sending requests

Scripts can send requests of their own, such as refreshing a token before the request that needs it. Reqling sends each one, with the project's cookies and certificates:

```js
// Pre-request: refresh the token once it has expired.
if (Date.now() > Number(rq.environment.get("tokenExpires") || 0)) {
  const res = await rq.sendRequest({
    method: "POST",
    url: rq.variables.replaceIn("{{authUrl}}/token"),
    body: { refresh_token: rq.environment.get("refreshToken") },
  })
  rq.environment.set("token", res.json().access_token, { secret: true })
  rq.environment.set("tokenExpires", Date.now() + res.json().expires_in * 1000)
}

// Send a saved request, resolved and authenticated as a run would be.
const login = await rq.runRequest("Login", { variables: { user: "ada" } })
rq.test("logged in", () => rq.expect(login.code).to.equal(200))
```

- **`rq.sendRequest`** takes a URL, or `{ method, url, headers, body, timeout }`, and sends it as given: `{{name}}` in it is plain text, so resolve one with `rq.variables.replaceIn`, and no auth is added. A body that isn't text, an `ArrayBuffer`, or a typed array goes as JSON. `timeout` is in milliseconds; left out, the request waits as long as **Settings ▸ Requests** says.
- **`rq.runRequest`** sends a saved HTTP or GraphQL request, by name or ID, as a run would: with its auth, and with the variables scripts have set so far, which `{ variables }` beat. Its own scripts don't run, and it isn't kept in its history. A name more than one request has, or a gRPC or WebSocket request, is refused.
- **Responses.** Both resolve with the response, whatever its status: `code`, `status`, `headers`, `text()`, `json()`, and `base64()`. They reject when no response comes back. An event stream is read until it ends.
- **Console.** Each request is listed in the Tests tab's console with its method, URL, status, and time, secrets masked, as agents see it too. One that failed or didn't finish says so.
- **Time limit.** Requests count toward the script's time limit, and a script waits for the ones it sent, awaited or not, before it ends. One still out when its script ends is stopped.
- **Cookies.** A request carries the cookies scripts set, and what its response sets lands in the project's jar, which `rq.cookies` then reads.
- **Previews** send scripts' requests too, so Copy as cURL and GraphQL introspection get what a send would, but keep no cookie they receive.
- **Bounds.** Only http and https URLs go out, and a phase, or a stream handler on one event, can send 100 requests. Reqling sends six of a phase's at once.

## Results

- **Tests tab.** A run with scripts gains a **Tests** tab beside the response. It shows each script's tests, passed, failed, or skipped, with any error it threw, then everything the scripts printed in the console, with the requests they sent. Objects print as indented JSON. While a stream is open, it updates as its handlers finish each event.
- **Stream scripts.** A test a handler runs on every event shows once, as **Passed 498 of 500**, with its first failure's message and the event it failed on. A handler that throws shows its first error, the event it threw on, and how many events it threw for. Events that reached no handler are counted, with why, and the console keeps its newest 1,000 entries.
- **Status bar.** **Tests 2/3** counts the tests that passed of those that ran, a stream script's each once. It's green when all of them passed and no script threw, and red otherwise.
- **Failures.** A failed test, or a stream or post-response script that throws, marks the run failed even when the server answered 200. A pre-request script that throws stops the run before anything is sent, and the response pane shows its error and console instead.
- **Request tab.** Headers, metadata, and query parameters that a pre-request script added or replaced are marked `{}`.
- **Skipped.** A pre-request script that calls `rq.execution.skipRequest()` keeps the request from being sent. The rest of the pre-request scripts still run, and the run counts as not sent unless a test failed or a script threw. `rq.execution.setNextRequest()` matters only when a folder or project runs; a request run on its own ignores it.
- **History.** Each run in the history shows its test counts, and the history keeps the newest 512 KB of each phase's console.

## Editor help

- **Snippets.** The menu beside the phase picker inserts common code that fits the phase and the request's protocol: setting or reading a variable, saving a value from the JSON response, adding a header, signing with an HMAC, and testing the status code, a JSON field, or the response time. In a stream script, those that read JSON read each event or message. A snippet goes on the cursor's line when it's blank, otherwise on a new line after it, with the part to change, such as a variable's name, selected. A folder's or the project's scripts run for every protocol, so snippets that differ by protocol are under each protocol, inside `if (rq.info.protocol === "grpc") { … }`.
- **Completion.** Typing a name, a `.`, or a quote offers what fits there: Reqling's API for the phase and the request's protocol, the names a script declared, variable names inside a call such as `rq.environment.get("…")`, the keys of this request's latest JSON response after `rq.response.json().`, an options object's keys and values, as in `rq.sendRequest({ method: "`, a request's response after `await` or in `.then(res => res.`, and a handler's parameter, as in `rq.onEvent(event => event.`, as the event or message it gets. The highlighted suggestion is described beneath the list: what an API member or keyword does, which environments hold a variable or which scripts set it, and where a key sits in the response. Accepting a method adds its parentheses, with the cursor between them when it takes arguments. Press ⌃Space, ⌥Esc, or F5, or choose Edit ▸ Show Completions, to open it anywhere.
- **Parameter hints.** Typing `(` or `,` in a call shows the method's parameters above the line, with the one being typed highlighted and described, and what the method does. The highlight follows the cursor from argument to argument, and the hints close when it leaves the call or on Escape. Press ⇧⌘Space or ⌘P, or choose Edit ▸ Show Parameter Hints, to show them again inside a call. A function the script declares shows its parameters as written, with what a `/** … */` comment right above it says: its description, and `@param {type} name description` for each parameter.
- **Brackets and quotes.** Typing `(`, `[`, `{`, or a quote adds its closer with the cursor between them, unless a name follows it (or, for a quote, comes right before it, as in `don't`). `${` in a template string closes as `${}`. A closer typed before the one already there steps over it, and Backspace between an empty pair removes both. Inside strings and comments, brackets and quotes type as they are.
- **Hover.** Pointing at a name, or an options object's key, shows what it is. A Postman `pm` name also shows its Reqling equivalent.
- **Problems.** Syntax errors are underlined in red. What doesn't work where the script runs is underlined in yellow: a member that doesn't exist, one of another phase or protocol, a key an options object doesn't take or a value it doesn't (such as a cookie's `sameSite: "laxx"`), a library `require` doesn't load, and Postman's old API. The problems menu above the script lists them.
- **Variables scripts set.** A `{{name}}` that a script sets, such as a token a login's post-response script saves, isn't marked undefined, and its tooltip names the script. A name set with `rq.variables.set` counts only in requests whose own pre-request scripts set it.

## Scripts from Postman

Postman's `pm` names work as their Reqling equivalents do, so scripts brought from Postman run as they are: `pm.environment`, `pm.collectionVariables` (the Default environment), `pm.test`, `pm.expect`, `pm.response`, and the rest the [reference](#api-reference) lists. `pm.sendRequest`, with a callback or as a promise, and `pm.execution.runRequest` send requests as their Reqling equivalents do ([Sending requests](#sending-requests)). A few can't work in Reqling and throw a clear error: `pm.vault`, `pm.visualizer`, and a `pm.sendRequest` with a file or its own `auth`. Postman's old API, such as `postman.setEnvironmentVariable`, `tests["…"]`, and `responseBody`, isn't there either, nor are libraries besides `crypto-js` and `lodash`; the editor underlines each, with the `pm` name to use where there is one. The editor completes only `rq`, and hovering a `pm` name shows its Reqling equivalent.

## Trust

Scripts can read a project's variables and Global's, secrets included, so a project's scripts run on this Mac only once you trust them.

- **The first time** a request with scripts is sent in a project you didn't create here, Reqling lists its script files and asks. **Trust Scripts** and **Don't Run** are both remembered on this Mac.
- **Projects you create** in Reqling, or that an agent creates through MCP, are trusted from the start. One [imported from Postman](projects.md#importing-from-postman) with scripts asks first, since someone else wrote them.
- **Without trust,** requests go out without their scripts, and the response says so, with a **Trust Scripts** button for the next run. Agents' runs and background schema lookups never ask; they skip the scripts.
- **Running a folder or project** asks once for the whole run, listing every script it would run ([Running folders and projects](running-folders.md)).
- **Change it** in the project's pane, under its scripts.

## Libraries and limits

- **Built in:** `rq.crypto` for MD5, SHA, and HMAC digests, `btoa` and `atob`, `crypto.getRandomValues` and `crypto.randomUUID`, `console`, `setTimeout`, and `setInterval`.
- **Libraries:** crypto-js as `CryptoJS` and lodash as `_`, also through `require("crypto-js")` and `require("lodash")`.
- **Not available:** files. Requests go out only through Reqling ([Sending requests](#sending-requests)).
- **Time limit.** Each phase may run for 10 seconds by default, and so may a stream script's top level and its handlers on each event; change it in **Settings ▸ Requests**. Scripts run in a separate process, which Reqling stops at the limit. Handlers past it stop the stream scripts there, naming the event, while the stream itself goes on.
- **Responses** reach scripts whole, up to 64 MB.

## API reference

Every name a script can use, as Reqling's editor completes and describes it. A member marked with phases, such as *pre-request only* or *stream and post-response only*, works only in those phases, and one marked with a protocol works only for requests of that protocol; an event stream's is HTTP.

<!-- script-reference:start -->

### Globals

- `rq: Reqling`: Reqling's script API: variables, the request, the response, and tests.
- `console: Console`: Logs to the response's Tests tab.
- `crypto: WebCrypto`: Random values, as the Web Crypto API gives them.
- `btoa(text: string): string`: Base64 of text whose characters are each a byte.
- `atob(base64: string): string`: Decodes base64 to text with a character per byte.
- `setTimeout(callback: function, delay?: number): number`: Runs the callback once, after the delay in milliseconds.
- `setInterval(callback: function, delay?: number): number`: Runs the callback every delay milliseconds.
- `clearTimeout(id: number): void`: Cancels a timeout.
- `clearInterval(id: number): void`: Cancels an interval.
- `require(name: string): any`: Loads `crypto-js` or `lodash`.
- `CryptoJS: CryptoJS`: crypto-js 4.2.0, loaded on first use.
- `_: Lodash`: lodash 4.17.21, loaded on first use.

### `Reqling`

Reqling's script API.

- `info: Info`: Where this script runs: its phase, level, request, and environment.
- `environment: Environment`: The active environment's variables. A value set here is kept on this Mac.
- `defaultEnvironment: DefaultEnvironment`: The project's Default environment's variables.
- `globals: Globals`: The Global environment's variables.
- `variables: Variables`: Every variable as `{{name}}` resolves it; a value set here lasts for this run.
- `iterationData: IterationData`: This iteration's row of a folder or project run's data file.
- `execution: Execution`: Skips this request, or picks what a folder or project run runs next.
- `request: Request`: The request as typed. Pre-request scripts can change its headers and query.
- `cookies: RequestCookies`: The project's cookies for this request's URL, or for any other through `for(…)`.
- `response: Response`: What came back; in a stream script, what the stream opened with. *(stream and post-response only)*
- `onEvent(handler: (event: StreamEvent) => void): void`: Runs the handler on each event the stream receives, in order. *(stream, HTTP only)*
- `onMessage(handler: (message: SocketMessage) => void): void`: Runs the handler on each message received, in order. *(stream, WebSocket only)*
- `onMessage(handler: (message: GRPCMessage) => void): void`: Runs the handler on each message received, in order. *(stream, gRPC only)*
- `send(message: any): void`: Sends a message on the open connection, as given: `{{variables}}` in it aren't resolved. *(stream, WebSocket only)*
- `send(message: any): void`: Sends a message on the call's open request stream, as given: `{{variables}}` in it aren't resolved. *(stream, gRPC only)*
- `sendRequest(request: string | OutgoingRequest): Promise<IncomingResponse>`: Sends a request from Reqling, as given: `{{variables}}` in it aren't resolved. Resolves with the response, whatever its status, and rejects when none comes back.
- `runRequest(request: string, options?: RunRequestOptions): Promise<IncomingResponse>`: Sends a saved HTTP request as a run resolves it, auth included, without running its scripts or keeping it in its history.
- `test(name: string, callback: function): void`: Runs a named test; it fails when the callback throws or its promise rejects.
- `expect(value: any, message?: string): Expectation`: Starts a Chai-style assertion about a value.
- `crypto: Crypto`: Hashes and HMACs for signing requests.

### `Console`

Logs to the response's Tests tab; objects print as indented JSON.

- `log(...values: any[]): void`: Logs the values, separated by spaces.
- `info(...values: any[]): void`: Logs the values, separated by spaces.
- `warn(...values: any[]): void`: Logs the values, separated by spaces.
- `error(...values: any[]): void`: Logs the values, separated by spaces.
- `debug(...values: any[]): void`: Logs the values, separated by spaces.

### `WebCrypto`

Random values.

- `getRandomValues(array: object): object`: Fills an integer typed array with random values.
- `randomUUID(): string`: A random UUID.

### `CryptoJS`

crypto-js 4.2.0. Lists the most used of its members.

- `MD5(message: any): object`: Hashes the message.
- `SHA1(message: any): object`: Hashes the message.
- `SHA256(message: any): object`: Hashes the message.
- `SHA512(message: any): object`: Hashes the message.
- `HmacSHA1(message: any, key: any): object`: An HMAC of the message.
- `HmacSHA256(message: any, key: any): object`: An HMAC of the message.
- `HmacSHA512(message: any, key: any): object`: An HMAC of the message.
- `enc: object`: Encoders: `Hex`, `Base64`, `Utf8`, and others.
- `lib: object`: Building blocks, such as `WordArray`.
- `AES: object`: AES encryption.

### `Lodash`

lodash 4.17.21. Lists the most used of its members.

- `get(...args: any[]): any`: lodash's `get`.
- `set(...args: any[]): any`: lodash's `set`.
- `pick(...args: any[]): any`: lodash's `pick`.
- `omit(...args: any[]): any`: lodash's `omit`.
- `map(...args: any[]): any`: lodash's `map`.
- `filter(...args: any[]): any`: lodash's `filter`.
- `find(...args: any[]): any`: lodash's `find`.
- `chunk(...args: any[]): any`: lodash's `chunk`.
- `uniq(...args: any[]): any`: lodash's `uniq`.

### `Info`

Where this script runs.

- `phase: string`: `preRequest`, `stream`, or `postResponse`.
- `level: string`: Whose script this is: `project`, `folder`, or `request`.
- `levelName: string`: The project's, folder's, or request's name.
- `requestName: string`: The name of the request running.
- `requestId: string`: The ID of the request running.
- `protocol: string`: `http`, `grpc`, or `websocket`.
- `environment: string`: The active environment's name.
- `iteration: number`: Which iteration of a folder or project run this is, from 0; 0 when the request runs on its own.
- `iterationCount: number`: How many iterations the folder or project run makes; 1 when the request runs on its own.

### `Environment`

The active environment's variables: its saved values, with this Mac's current values over them.

- `get(name: string): string | null`: The variable's value, or `undefined`.
- `set(name: string, value: any, options?: VariableOptions): void`: Sets a value; anything but a string is stored as JSON. `{ secret: true }` keeps it in the Keychain and masked.
- `unset(name: string): void`: Hides the variable until its current value is reset in the Environments sheet.
- `has(name: string): boolean`: Whether the variable has a value.
- `isSecret(name: string): boolean`: Whether the variable's value is secret.
- `toObject(): object`: Every variable with its value.
- `name: string`: The environment's name.

### `DefaultEnvironment`

The project's Default environment's variables.

- `get(name: string): string | null`: The variable's value, or `undefined`.
- `set(name: string, value: any, options?: VariableOptions): void`: Sets a value; anything but a string is stored as JSON. `{ secret: true }` keeps it in the Keychain and masked.
- `unset(name: string): void`: Hides the variable until its current value is reset in the Environments sheet.
- `has(name: string): boolean`: Whether the variable has a value.
- `isSecret(name: string): boolean`: Whether the variable's value is secret.
- `toObject(): object`: Every variable with its value.
- `name: string`: The environment's name.

### `Globals`

The Global environment's variables, which every project shares.

- `get(name: string): string | null`: The variable's value, or `undefined`.
- `set(name: string, value: any, options?: VariableOptions): void`: Sets a value; anything but a string is stored as JSON. `{ secret: true }` keeps it in the Keychain and masked.
- `unset(name: string): void`: Hides the variable until its current value is reset in the Environments sheet.
- `has(name: string): boolean`: Whether the variable has a value.
- `isSecret(name: string): boolean`: Whether the variable's value is secret.
- `toObject(): object`: Every variable with its value.
- `name: string`: The environment's name.

### `Variables`

Every variable as `{{name}}` resolves it; values set here last only for this run.

- `get(name: string): string | null`: The variable's value, or `undefined`.
- `set(name: string, value: any, options?: VariableOptions): void`: Sets a value; anything but a string is stored as JSON. `{ secret: true }` keeps it in the Keychain and masked.
- `unset(name: string): void`: Drops a value set earlier in this run.
- `has(name: string): boolean`: Whether the variable has a value.
- `isSecret(name: string): boolean`: Whether the variable's value is secret.
- `toObject(): object`: Every variable with its value.
- `replaceIn(text: string): string`: Resolves `{{name}}` references as the request will.

### `IterationData`

This iteration's row of a folder or project run's data file, as text. Empty otherwise.

- `get(name: string): string | null`: The column's value in this row, or `undefined`.
- `has(name: string): boolean`: Whether this row has the column.
- `toObject(): object`: Every column of this row with its value.

### `Execution`

What happens to this request, and what a folder or project run runs next.

- `skipRequest(): void`: Doesn't send this request. The rest of the pre-request scripts still run. *(pre-request only)*
- `setNextRequest(request: string | null): void`: In a folder or project run, runs the request with this name or ID next; `null` ends the iteration. Ignored when the request runs on its own.

### `Request`

The request as typed, `{{variables}}` unresolved.

- `protocol: string`: `http`, `grpc`, or `websocket`.
- `url: string`: The URL without its query, or a gRPC call's target.
- `method: string`: The HTTP method. *(HTTP only)*
- `body: RequestBody | null`: The body as typed. *(HTTP only)*
- `headers: Rows`: The headers, or a gRPC call's metadata.
- `query: Rows`: The query parameters. *(HTTP and WebSocket only)*
- `metadata: Rows`: The call's metadata. *(gRPC only)*
- `service: string`: The call's service. *(gRPC only)*
- `rpc: string`: The call's method. *(gRPC only)*
- `messages: string[]`: The messages it sends, as typed. *(gRPC and WebSocket only)*

### `RequestCookies`

The project's cookies that go to this request's URL. Pre-request changes go out with the request, and every change stays in the project's jar until Reqling quits.

- `get(name: string): string | null`: The value of the first cookie with the name, or `undefined`. *(HTTP and WebSocket only)*
- `has(name: string): boolean`: Whether a cookie has the name. *(HTTP and WebSocket only)*
- `all(): Cookie[]`: Every cookie, the most specific first. *(HTTP and WebSocket only)*
- `toObject(): object`: Every cookie's value by name. *(HTTP and WebSocket only)*
- `set(name: string, value: any, options?: CookieOptions): void`: Sets a cookie for path `/` and this host alone, lasting until Reqling quits, unless `{ path, domain, expires, secure, httpOnly, sameSite }` say otherwise. An `expires` already past removes it. *(HTTP and WebSocket only)*
- `remove(name: string): void`: Removes every cookie with the name. *(HTTP and WebSocket only)*
- `clear(): void`: Removes every cookie. *(HTTP and WebSocket only)*
- `for(target: string): Cookies`: The cookies for another URL, or every cookie for a bare domain such as `example.com`; `{{variables}}` resolve.

### `Response`

What came back: an HTTP response, an event stream, a gRPC call, or a WebSocket connection.

- `code: number`: The HTTP status code. *(stream and post-response, HTTP only)*
- `code: number | null`: The gRPC status code; 0 is OK. *(post-response, gRPC only)*
- `code: number | null`: The handshake's HTTP status code. *(stream and post-response, WebSocket only)*
- `status: string`: The HTTP reason phrase, such as `OK`. *(stream and post-response, HTTP only)*
- `status: GRPCStatus`: How the call ended. *(post-response, gRPC only)*
- `headers: ReadonlyRows`: The response's headers, or the handshake's. *(stream and post-response, HTTP and WebSocket only)*
- `size: number`: The body's size in bytes, as received. *(post-response, HTTP only)*
- `truncated: boolean`: Whether the body was cut to the 64 MB scripts receive. *(post-response, HTTP only)*
- `responseTime: number`: How long it took, in milliseconds. *(post-response only)*
- `text(): string`: The body as text. *(post-response, HTTP only)*
- `json(): any`: The body, or the last message received, parsed as JSON. *(post-response, HTTP and gRPC only)*
- `base64(): string`: The body's bytes, base64. *(post-response, HTTP only)*
- `events: StreamEvent[]`: Every event received, in order. *(post-response, HTTP only)*
- `omittedEventCount: number`: Events received but not kept. *(post-response, HTTP only)*
- `end: string`: How the stream or connection ended: `closed`, `stopped`, `limit`, `timedOut`, `refused`, or `failed`. *(post-response, HTTP and WebSocket only)*
- `metadata: ReadonlyRows`: The call's response metadata. *(stream and post-response, gRPC only)*
- `trailers: ReadonlyRows`: The call's trailers. *(post-response, gRPC only)*
- `messages: GRPCMessage[]`: Every message received, in order. *(post-response, gRPC only)*
- `sentCount: number`: How many messages the call sent. *(post-response, gRPC only)*
- `receivedCount: number`: How many messages the call received. *(post-response, gRPC only)*
- `messages: SocketMessage[]`: Every message sent and received, in order. *(post-response, WebSocket only)*
- `subprotocol: string | null`: The subprotocol the server chose. *(stream and post-response, WebSocket only)*
- `close: Close | null`: How the connection closed, if it did. *(post-response, WebSocket only)*

### `StreamEvent`

One event of an event stream.

- `id: string | null`: Its `id:`.
- `event: string | null`: Its `event:` type.
- `data: string`: Its data.
- `retry: number | null`: Its `retry:` delay, in milliseconds.
- `json(): any`: Its data, parsed as JSON.

### `SocketMessage`

One message the connection sent or received.

- `direction: string`: `sent` or `received`.
- `text: string | null`: A text message's text.
- `isBinary: boolean`: Whether it was a binary message.
- `base64: string | null`: A binary message's bytes, base64.
- `json(): any`: A text message, parsed as JSON.

### `GRPCMessage`

One message the call received.

- `text(): string`: The message as JSON text.
- `json(): any`: The message, parsed.

### `IncomingResponse`

What a request a script sent got back.

- `code: number`: The HTTP status code.
- `status: string`: The HTTP reason phrase, such as `OK`.
- `headers: ReadonlyRows`: The response's headers.
- `size: number`: The body's size in bytes, as received.
- `truncated: boolean`: Whether the body was cut to the 64 MB scripts receive.
- `responseTime: number`: How long it took, in milliseconds.
- `text(): string`: The body as text.
- `json(): any`: The body, parsed as JSON.
- `base64(): string`: The body's bytes, base64.

### `OutgoingRequest`

A request for `rq.sendRequest` to send, as given.

- `method: string`: The HTTP method; `GET` when left out.
- `url: string`: The URL, as given; `rq.variables.replaceIn` resolves `{{variables}}` first.
- `headers: object`: An object of names and values, or `[name, value]` pairs.
- `body: any`: Text, an `ArrayBuffer` or typed array, or any other value as JSON, which adds a JSON `Content-Type` unless `headers` name one.
- `timeout: number`: How long to wait for the response, in milliseconds; as long as Settings ▸ Requests says when left out. The script's own time limit still applies.

### `RunRequestOptions`

How `rq.runRequest` sends a saved request.

- `variables: object`: Values that beat every other for this request, by name.

### `TestFunction`

Runs a named test.

- `skip(name: string, callback?: function): void`: Reports a test as skipped without running it.

### `Expectation`

A Chai-style assertion: chain words such as `to`, `be`, and `have`, `.not`, `.deep`, and assertions such as `equal`, `include`, and `property`. Lists the most used of its members.

- `to: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `be: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `been: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `is: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `that: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `which: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `and: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `has: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `have: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `with: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `at: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `of: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `same: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `not: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `deep: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `own: Expectation`: Reads on; `not` negates and `deep` compares deeply.
- `equal(expected: any): Expectation`: Strictly equal, or deeply after `.deep`.
- `eql(expected: any): Expectation`: Deeply equal.
- `include(expected: any): Expectation`: Contains the value, substring, or subset.
- `property(name: string, value?: any): Expectation`: Has the property, with the value when given; chains on to it.
- `a(type: string): Expectation`: Is of the type: `string`, `array`, `null`, …
- `above(expected: any): Expectation`: Greater than.
- `below(expected: any): Expectation`: Less than.
- `least(expected: any): Expectation`: At least.
- `most(expected: any): Expectation`: At most.
- `within(low: number, high: number): Expectation`: In the range.
- `match(pattern: any): Expectation`: Matches the regular expression.
- `lengthOf(length: number): Expectation`: Has the length or size.
- `oneOf(values: any[]): Expectation`: Is one of the values.
- `keys(...names: string[]): Expectation`: Has exactly the keys.
- `members(values: any[]): Expectation`: Has the same members.
- `throw(expected?: any): Expectation`: The function throws.
- `ok: Expectation`: Asserts as it's read.
- `true: Expectation`: Asserts as it's read.
- `false: Expectation`: Asserts as it's read.
- `null: Expectation`: Asserts as it's read.
- `undefined: Expectation`: Asserts as it's read.
- `exist: Expectation`: Asserts as it's read.
- `empty: Expectation`: Asserts as it's read.
- `NaN: Expectation`: Asserts as it's read.

### `Crypto`

Hashes and HMACs. Output is hex unless `{ encoding: "base64" }`; input is UTF-8 text unless `{ inputEncoding: "hex" | "base64" }`.

- `md5(data: string, options?: object): string`: The MD5 hash.
- `sha1(data: string, options?: object): string`: The SHA1 hash.
- `sha256(data: string, options?: object): string`: The SHA256 hash.
- `sha384(data: string, options?: object): string`: The SHA384 hash.
- `sha512(data: string, options?: object): string`: The SHA512 hash.
- `hmac(algorithm: string, key: string, data: string, options?: object): string`: An HMAC with `md5`, `sha1`, `sha256`, `sha384`, or `sha512`; `{ keyEncoding }` reads the key as hex or base64.
- `randomUUID(): string`: A random UUID.

### `VariableOptions`

How `set` stores a variable's value.

- `secret: boolean`: Keeps the value in the Keychain, and masks it wherever it would show.

### `RequestBody`

An HTTP request's body as typed.

- `mode: string`: `none`, `raw`, `formData`, `urlEncoded`, `binary`, or `graphQL`.
- `raw: string | null`: The raw body's text.
- `fields: Row[]`: Form fields; a file field's value is its path.
- `graphQL: GraphQLBody | null`: A GraphQL body's query, variables, and operation name.

### `Rows`

Headers, query parameters, or metadata. Pre-request scripts can change them for this run.

- `get(name: string): string | null`: The first value with the name, or `undefined`; header names ignore case.
- `has(name: string): boolean`: Whether an entry has the name.
- `all(): Row[]`: Every entry, in order.
- `toObject(): object`: Every entry by name.
- `upsert(name: string, value: any): void`: Sets the first entry with the name, dropping the others, or adds one. *(pre-request only)*
- `add(name: string, value: any): void`: Adds an entry. *(pre-request only)*
- `remove(name: string): void`: Drops every entry with the name. *(pre-request only)*

### `Cookie`

One cookie.

- `name: string`: Its name.
- `value: string`: Its value.
- `domain: string`: The host it's for, without a leading dot.
- `path: string`: The path it's sent under.
- `expires: string | null`: When it expires, in ISO 8601; `null` lasts until Reqling quits.
- `secure: boolean`: Sent only over HTTPS, and to localhost.
- `httpOnly: boolean`: Marked `HttpOnly`.
- `sameSite: string | null`: `lax`, `strict`, `none`, or `null`.
- `hostOnly: boolean`: Sent only to `domain` itself, not to its subdomains.

### `CookieOptions`

How `set` sets a cookie.

- `path: string`: The path it's sent under; `/` when left out.
- `domain: string`: A domain it goes to with its subdomains; this host alone when left out.
- `expires: any`: A `Date`, a date string, or milliseconds since 1970; until Reqling quits when left out. One already past removes the cookie.
- `secure: boolean`: Sends it only over HTTPS, and to localhost.
- `httpOnly: boolean`: Marks it `HttpOnly`.
- `sameSite: string`: `lax`, `strict`, or `none`.

### `Cookies`

The project's cookies for a URL, or every cookie for a domain.

- `get(name: string): string | null`: The value of the first cookie with the name, or `undefined`.
- `has(name: string): boolean`: Whether a cookie has the name.
- `all(): Cookie[]`: Every cookie, the most specific first.
- `toObject(): object`: Every cookie's value by name.
- `set(name: string, value: any, options?: CookieOptions): void`: Sets a cookie for path `/` and this host alone, lasting until Reqling quits, unless `{ path, domain, expires, secure, httpOnly, sameSite }` say otherwise. An `expires` already past removes it.
- `remove(name: string): void`: Removes every cookie with the name.
- `clear(): void`: Removes every cookie.

### `GRPCStatus`

How the call ended.

- `code: number | null`: The status code; 0 is OK.
- `name: string | null`: The status's canonical name, such as `OK` or `NOT_FOUND`.
- `message: string | null`: The server's message.

### `ReadonlyRows`

Headers, metadata, or trailers.

- `get(name: string): string | null`: The first value with the name, or `undefined`; header names ignore case.
- `has(name: string): boolean`: Whether an entry has the name.
- `all(): Row[]`: Every entry, in order.
- `toObject(): object`: Every entry by name.

### `Close`

How the connection closed.

- `code: number`: The close code.
- `reason: string`: The close reason.

### `Row`

One header, query parameter, or metadata entry.

- `name: string`: Its name.
- `value: string`: Its value, `{{variables}}` unresolved.

### `GraphQLBody`

A GraphQL body.

- `query: string`: The query.
- `variables: string`: The variables, as JSON text.
- `operationName: string | null`: The operation to run, when the query has several.

### Postman's `pm`

Scripts from Postman run as they are. Each name works like its Reqling equivalent:

- `pm.test`: `rq.test`
- `pm.expect`: `rq.expect`
- `pm.info`: `rq.info`
- `pm.environment`: `rq.environment`
- `pm.globals`: `rq.globals`
- `pm.collectionVariables`: `rq.defaultEnvironment`
- `pm.variables`: `rq.variables`
- `pm.request`: `rq.request`
- `pm.response`: `rq.response`
- `pm.sendRequest`: `rq.sendRequest`
- `pm.cookies`: `rq.cookies`
- `pm.vault`: not supported, since Reqling keeps secrets as secret variables
- `pm.iterationData`: `rq.iterationData`
- `pm.execution`: `rq.execution`
- `pm.visualizer`: not supported, since Reqling shows responses itself

<!-- script-reference:end -->
