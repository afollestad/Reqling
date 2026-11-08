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
- **Renaming.** A new folder or request starts with its name ready to type, and Return renames the selected item in place. Renames move files rather than rewriting them.
- **Deleting** asks first, then moves the files to the Trash.
- **Outside edits** (a `git pull`, an editor) appear in the window as soon as they land.
- **Filter the sidebar** by name, method, URL, or gRPC service, and narrow it by protocol, by method, or by how each request's last run went.

## Importing from Postman

Choose **File ▸ Import Postman Collection…**, also in the sidebar's add menu, and pick a collection exported from Postman (Collection v2.1 or v2.0) with any of its environment and globals exports. Reqling makes a new project from them, then sums up what came over and what needs changes.

- **Requests and folders** keep their order, with their methods, URLs, query parameters, headers, and bodies: raw, sent as the type Postman sent it as, form-data, URL-encoded, binary, and GraphQL. Turned-off rows stay turned off.
- **Auth.** Basic, bearer, and API key auth carry over: the collection's becomes the project's, and each folder's its own. A password, token, or key typed into Postman's auth becomes a secret variable in Default, such as `{{bearerToken}}`, so it's kept in your Keychain rather than the project's files. Other auth types become none, and the summary lists them.
- **Variables.** The collection's variables go into Default, each environment becomes the project's, and a globals export joins Global. Path variables such as `:id` stay [path variables](requests.md#building-a-request), with the values Postman gave them.
- **Files** for bodies are found where Postman had them, beside the collection, or in Postman's files folder. One inside the project's repository is shared by a relative path, and any other is kept on this Mac only. One that isn't found is left for you to choose.
- **Scripts** become each level's own, the collection's the project's, and run as they are ([Scripts from Postman](scripts.md#scripts-from-postman)). Since someone else wrote them, the project asks before running them. The summary lists what in them needs changes, as the editor underlines it.
- **Not imported:** descriptions, saved example responses, folders' and requests' own variables, and settings Reqling doesn't have.
- **Into a project you have.** To bring Postman environments or globals into an existing project, choose the import button under the list in its Environments sheet. Each merges into the environment of its name: Postman's values replace the saved ones, except that an empty value never blanks one and a secret stays secret. Done saves them.

## Environments

- **Default.** Every project has its own. Add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar.
- **Global** sits at the top of every project's Environments sheet and holds variables every project shares. It's kept on your Mac, never in a project, and each project's environments override it by key.
- **The active environment** is never written into the project, nor is anything else specific to your Mac.

## Variables

- **Reference** one as `{{name}}` in the URL, parameters, headers, bodies, and auth.
- **Built-ins** generate a value on each send: `{{$uuid}}`, `{{$timestamp}}` (Unix seconds), `{{$isoTimestamp}}`, and `{{$randomInt}}` (0 to 1,000), plus Postman's random values, such as `{{$randomEmail}}`, `{{$randomFullName}}`, `{{$randomIP}}`, `{{$randomPrice}}`, and `{{$randomDatePast}}`. Typing `{{$` lists them all. Postman's `{{$guid}}` and `{{$randomUUID}}` work as `{{$uuid}}`.
- **Pills.** Variables render as pills, red when undefined, and typing `{{` offers completion.
- **Secrets.** Mark a variable secret to keep its value in your Keychain instead of the project's files.

## Current values

- **Set by scripts.** When a script sets an environment or Global variable, the value is kept on your Mac as that environment's *current value*, which overrides the saved value by key. It never goes into the project, so running requests never changes `git status`.
- **Secret ones** stay in your Keychain and are masked wherever they show. A value is secret when its variable is, when the script asks for it, or when it contains another secret, such as `"Bearer " + token`.
- **Unset.** A script that unsets a variable hides its saved value until you reset it.
- **In the Environments sheet,** current values are listed under the variables. Reset one, or all of them, to use the saved values again, or Save as Value to make one the saved value everyone shares.
- **Editing a variable's saved value** in Reqling drops its current value, so your edit takes effect. Changes pulled from git leave current values alone.
