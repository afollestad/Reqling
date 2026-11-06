# Scripts

JavaScript that runs before a request is sent and after its response comes back, for HTTP, GraphQL, gRPC, and WebSocket requests alike. Use scripts to compute a signature or timestamp, to save a token from a login's response for the requests after it, and to test what came back.

## Where scripts live

- **Requests.** A request's **Scripts** tab holds its **Pre-request** and **Post-response** scripts.
- **Folders and the project.** Select a folder or the project to edit scripts that run for every request inside it.
- **Files.** Each script is a `.js` file beside its owner's JSON, such as `list-users.pre.js`, `_folder.post.js`, or `project.pre.js`, so scripts travel with the project through git. An empty script has no file.
- **Badges.** The sidebar marks requests and folders that have scripts of their own.

## Order

In each phase, the project's script runs first, then each folder's from the outermost in, then the request's own.

- **Runs after** lists the scripts that run before the one you're editing. Click one to open it.
- **Run inherited scripts**, turned off on a request, runs only that request's own scripts. Turned off on a folder, it stops the scripts above that folder for every request inside it.
