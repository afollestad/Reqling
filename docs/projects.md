# Projects

A project is a folder of small JSON files, so it diffs cleanly and can live in your API's own git repository.

```
My API.reqling/
  project.json
  project.pre.js
  environments/default.json
  environments/staging.json
  requests/users/_folder.json
  requests/users/list-users.json
  requests/users/list-users.post.js
```

Scripts sit beside the file they belong to, as `.pre.js` (before the request), `.stream.js` (while a stream is open), and `.post.js` (after the response), and move with it when it's renamed or moved.

## Working with projects

- **Create** a project in Reqling's own folder, or choose a location such as a repository, then add folders and requests in the sidebar.
- **Open a shared one** with **Add Project Folder…**.
- **Folders** open and close with a click, or with → and ← when selected. ← inside a folder selects it, and a click on its icon opens or closes it without selecting it.
- **Renaming.** A new folder or request starts with its name ready to type, and Return renames the selected item in place. Renames move files rather than rewriting them.
- **Deleting** asks first, then moves the files to the Trash, on every Mac that [syncs](#syncing-with-icloud) the project.
- **Outside edits** (a `git pull`, an editor) appear in the window as soon as they land.
- **Files** a request or the project uses, such as a body, a schema, or a certificate, are shared by a path relative to the project when they sit inside its folder or repository. For a file elsewhere, Reqling asks whether to share its path, for everyone with the same folder layout, or remember it on this Mac only.
  - A shared path that leads outside the folder and repository, directly or through a symlink, works only on a Mac where someone chose it. Elsewhere it counts as missing until it's chosen there, so a project someone else wrote can't read your other files.
  - A file kept on this Mac only, or a shared path chosen outside the folder and repository, works only in the field it was chosen for, and in copies you make of its request by duplicating or moving it. If someone else's change, from a repository or another Mac, puts it in another field, it's missing there until you choose it again.
- **Filter the sidebar** by name, method, URL, or gRPC service, and narrow it by protocol, by method, or by how each request's last run went.

## Syncing with iCloud

Reqling syncs through your iCloud account, so each Mac signed in to it has the same projects. It's on by default; Settings ▸ iCloud turns it off.

- **What syncs:** projects in Reqling's own folder, Global, and current values, secret values included. A project anywhere else, such as in a repository, stays on its Mac, for git to share. Run history, the active environment, the files requests use, Keychain identities, and certificate passphrases stay on each Mac too.
- **What Apple sees.** Everything you write is end-to-end encrypted. Apple sees only each record's kind (a project, folder, request, or environment), its ID, its size, and when it changed.
- **Every Mac signed in to the account can change** the projects that sync. Scripts another Mac changed ask for [trust](scripts.md#trust) again before they run here, and a file chosen on one Mac stays missing on another until it's chosen there.
- **Edits on two Macs** merge field by field. Where both changed the same field, the later edit wins.
- **On a new Mac,** the first sync brings every project, Global, and current value, secret values into its Keychain. Projects with scripts ask for trust before they first run.
- **A backup** of Reqling's projects folder, Global, and current values is taken before a Mac first syncs. **Show Backup in Finder** in Settings ▸ iCloud opens it.
- **Deleting** a project, folder, or request that syncs moves it to the Trash on every Mac, where Finder can put it back; the other Macs keep its secret values in their Keychains. When several projects are deleted at once, Reqling asks before trashing them. **Remove from Reqling** only stops syncing it on this Mac.
- **Another iCloud account** signing in pauses sync until you choose which of this Mac's projects merge into it, if any.
- **Deleting Reqling's data** from iCloud in System Settings (**Open iCloud Settings…**) turns sync off and leaves your project folders as they are. Turning it on again uploads them.
- **A project changed by a newer Reqling** stops syncing on this Mac, as Settings ▸ iCloud lists, until you update. Edits you make to it meanwhile sync then.

## Importing

Choose **File ▸ Import…** (⇧⌘I), also in the sidebar's add menu, and give it a Postman collection or an OpenAPI 3 document: choose a file, or type a URL or a file's path and press **Load**. Reqling tells which it is from what's inside, says what it found, then makes a new project and sums up what came over and what needs changes.

### From Postman

Load a collection exported from Postman (Collection v2.1 or v2.0), then add any of its environment and globals exports under **Environments**.

- **Requests and folders** keep their order, with their methods, URLs, query parameters, headers, and bodies: raw, sent as the type Postman sent it as, form-data, URL-encoded, binary, and GraphQL. Turned-off rows stay turned off.
- **Auth.** Basic, bearer, and API key auth carry over: the collection's becomes the project's, and each folder's its own. A password, token, or key typed into Postman's auth becomes a secret variable in Default, such as `{{bearerToken}}`, so it's kept in your Keychain rather than the project's files. Other auth types become none, and the summary lists them.
- **Variables.** The collection's variables go into Default, each environment becomes the project's, and a globals export joins Global. Path variables such as `:id` stay [path variables](requests.md#building-a-request), with the values Postman gave them.
- **Files** for bodies are found where Postman had them, beside the collection, or in Postman's files folder. One inside the project's repository is shared by a relative path, and any other is kept on this Mac only. One that isn't found is left for you to choose.
- **Scripts** become each level's own, the collection's the project's, and run as they are ([Scripts from Postman](scripts.md#scripts-from-postman)). Since someone else wrote them, the project asks before running them. The summary lists what in them needs changes, as the editor underlines it.
- **Not imported:** descriptions, saved example responses, folders' and requests' own variables, and settings Reqling doesn't have.
- **Into a project you have.** To bring Postman environments or globals into an existing project, choose the import button under the list in its Environments sheet. Each merges into the environment of its name: Postman's values replace the saved ones, except that an empty value never blanks one and a secret stays secret. Done saves them.

### From OpenAPI

Load an OpenAPI 3.0, 3.1, or 3.2 document, in JSON or YAML. A Swagger 2.0 document needs converting to OpenAPI 3 first.

- **Requests** are one per operation, named by its summary, then its `operationId`, then its method and path. Each sits in the folder of its first tag, in the order the document lists its tags, and 3.2's tag `parent` nests folders. Untagged operations sit at the top, after the folders.
- **URLs** start with `{{baseUrl}}`. A path parameter that is a whole segment becomes a [path variable](requests.md#building-a-request) (`/pets/{petId}` becomes `/pets/:petId`) with its example as its value. One inside a segment, as in `/files/{name}.{ext}`, becomes a variable in Default instead.
- **Servers.** The first server's URL is `baseUrl` in Default, with each server variable such as `{region}` as `{{region}}` beside it. With more than one server, each also gets an environment, named by its description. A relative server URL is relative to a document loaded from a URL; in a file, put the server's address in `baseUrl` yourself.
- **Parameters** become query parameters and headers, turned on when required and off otherwise, each valued from its example. Cookie parameters make one `Cookie` header. `Accept`, `Content-Type`, and `Authorization` header parameters are left out, as OpenAPI says.
- **Bodies** prefer JSON, then forms, then YAML, XML, and text, and anything else is a binary body whose file you choose. The example is the document's own or one made from its schema, without read-only properties. A multipart file part is left for you to choose.
- **Auth.** Basic, bearer, and API key schemes in a header or the query carry over, as do OAuth 2.0 and OpenID Connect as bearer auth whose token you get yourself. Each scheme's credentials are empty secret variables in Default, such as `{{bearerToken}}`, for you to fill in. The document's security becomes the project's auth, a folder takes the auth every request in it shares, and a request whose security differs keeps its own. Where security offers a choice, the first Reqling can meet wins, and deprecated schemes are used only when nothing else can be met.
- **References** (`$ref`) are followed across the document and into other files beside it, or, for a document loaded from a URL, other URLs. A document loaded from a URL never reads files on this Mac. What couldn't be loaded shows under the source before you import, and in the summary where it's used.
- **Not imported:** responses, callbacks, links, webhooks, and descriptions, which the summary counts.

## Environments

- **Default.** Every project has its own. Add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar.
- **Global** sits at the top of every project's Environments sheet and holds variables every project shares. It's kept apart from your projects, and each project's environments override it by key.
- **The active environment** is never written into the project, nor is anything else specific to your Mac.

## Variables

- **Reference** one as `{{name}}` in the URL, parameters, headers, bodies, and auth.
- **Built-ins** generate a value on each send: `{{$uuid}}`, `{{$timestamp}}` (Unix seconds), `{{$isoTimestamp}}`, and `{{$randomInt}}` (0 to 1,000), plus Postman's random values, such as `{{$randomEmail}}`, `{{$randomFullName}}`, `{{$randomIP}}`, `{{$randomPrice}}`, and `{{$randomDatePast}}`. Typing `{{$` lists them all. Postman's `{{$guid}}` and `{{$randomUUID}}` work as `{{$uuid}}`.
- **Pills.** Variables render as pills, red when undefined, and typing `{{` offers completion.
- **Secrets.** Mark a variable secret to keep its value in your Keychain instead of the project's files. [iCloud sync](#syncing-with-icloud) carries it to your other Macs' Keychains, end-to-end encrypted.

## Current values

- **Set by scripts.** When a script sets an environment or Global variable, the value is kept as that environment's *current value*, which overrides the saved value by key. It never goes into the project's files, so running requests never changes `git status`.
- **Secret ones** stay in your Keychain and are masked wherever they show. A value is secret when its variable is, when the script asks for it, or when it contains another secret, such as `"Bearer " + token`.
- **Unset.** A script that unsets a variable hides its saved value until you reset it.
- **In the Environments sheet,** current values are listed under the variables. Reset one, or all of them, to use the saved values again, or Save as Value to make one the saved value everyone shares.
- **Editing a variable's saved value** in Reqling drops its current value, so your edit takes effect, on every Mac that syncs it. Changes pulled from git leave current values alone.
