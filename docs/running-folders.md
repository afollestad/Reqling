# Running folders and projects

Run every request in a folder, or in a whole project, one after another in sidebar order. Scripts can chain the requests, a number of times over or once per row of a data file, and the sidebar shows how each one went.

## Starting a run

- **Run Folder…** or **Run Project…** is in a folder's or project's menu in the sidebar, on its pane, and in **Request ▸ Run Folder…** (⇧⌘↩). With a request selected, the command runs the folder it's in, or the project when it's at the top level.
- **The sheet** sets up the run:
  - **Environment.** The run uses this one throughout, whatever is active meanwhile.
  - **Iterations.** Repeat the requests a number of times, or once per row of a data file.
  - **On Failure.** Stop the run at the first request that fails, or carry on.
  - **Streams.** How long an event stream or WebSocket stays open before the run moves on (10 seconds unless you change it); its stream scripts handle what arrives, and its post-response scripts then run on it. gRPC calls end at their own deadline.
  - **Requests.** Untick any to leave them out; a folder's checkbox sets all of its own. Shift-click ranges and **Select All** / **Select None** work as elsewhere.
- **Remembered** until Reqling quits: the sheet opens with the settings the folder or project last ran with.
- **One run at a time,** whether you or an agent started it. **Stop Run** (⇧⌘.) or the bar's Stop button ends it.

## Results

- **Badges.** Each request in the run shows how it went across every iteration: a spinner while it runs, ✓ when it passed, ✗ when it failed in any iteration, and its tests passed of those that ran. A request without tests that ran more than once counts its iterations instead. Hover a badge to see which iterations failed.
- **Folders** roll up the requests inside them, so a collapsed folder still shows a failure.
- **The bar** at the foot of the sidebar says where the run is, or how it ended, with its counts, **Run Again**, and **Dismiss**.
- **Failed in Last Run,** in the sidebar's filter menu, narrows the sidebar to the requests that failed.
- **History.** Every request's run is in its own run history, as a Send's is, so select a request to see its latest run and pick an earlier iteration's there. A long run adds many runs to history, and the oldest go first once **Settings ▸ History** says it's full.
- **What counts as failed** is what the sidebar's Failed filter counts: a status of 400 or above, a gRPC status other than OK, a request that couldn't be sent, a script that threw, or a failed test.
- **Interrupted.** A request stopped by Stop (⌘.) in its editor, by the run's Stop, or by an agent, one you Send yourself while the run is on it, and one already running when the run reaches it are left alone and marked interrupted. That's not a failure, and the run goes on to the next request.

## Data files

Each row of a data file is one iteration, and each column a variable for it: `{{email}}` in a request, and `rq.iterationData.get("email")` in a script. A column beats an environment's variable of the same name.

- **CSV** needs a header row naming the columns. Quote a value to put a comma, quote (`""`), or line break in it. A row shorter than the header leaves its last columns out.
- **JSON** is an array of objects. Numbers and `true` or `false` become their text, a nested value becomes JSON, and `null` leaves the column out.
- **Values are text,** as every variable is; use `Number(…)` in a script for a number.
- **Up to 16 MB and 10,000 rows.** **Run Again** reads the file afresh.
- **Only in a run.** A column used as `{{name}}` reads as undefined in the editor, and a request sent on its own fails with it unresolved.

## Scripts in a run

- **Environment values** a script saves, such as a login's token, reach the requests after it, as they would if you sent them one by one.
- **`rq.variables`** values last until the iteration ends, so a request can use what an earlier one in the same iteration set. Each iteration starts without them.
- **`rq.info.iteration`** counts from 0, and **`rq.info.iterationCount`** says how many there are. A request sent on its own is iteration 0 of 1.
- **`rq.execution.setNextRequest("Name")`** runs that request next, by name or ID, even one earlier in the run, for a loop. `null` ends the iteration, as does a name the run doesn't hold, which the bar points out. The next iteration then starts from the top.
- **`rq.execution.skipRequest()`** in a pre-request script leaves that request out of this iteration.
- **Trust.** A project whose scripts you haven't decided on asks once for the whole run, listing every script it would run. Dismissing the question leaves the sheet open; without trust, the requests go out without their scripts, and the bar says so.

Postman's `pm.iterationData`, `pm.info.iteration`, and `pm.execution` work as their `rq` equivalents do, so a collection's scripts run here as they are. Agents can run a folder or project too ([MCP server](mcp.md)).
