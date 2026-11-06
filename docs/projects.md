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

Scripts sit beside the file they belong to, as `.pre.js` (before the request) and `.post.js` (after the response), and move with it when it's renamed or moved.

## Working with projects

- **Create** a project in Reqling's own folder, or choose a location such as a repository, then add folders and requests in the sidebar.
- **Open a shared one** with **Add Project Folder…**.
- **Renaming.** A new folder or request starts with its name ready to type, and Return renames the selected item in place. Renames move files rather than rewriting them.
- **Deleting** asks first, then moves the files to the Trash.
- **Outside edits** (a `git pull`, an editor) appear in the window as soon as they land.
- **Filter the sidebar** by name, method, URL, or gRPC service, and narrow it by protocol, by method, or by how each request's last run went.

## Environments

- **Default.** Every project has its own. Add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar.
- **Global** sits at the top of every project's Environments sheet and holds variables every project shares. It's kept on your Mac, never in a project, and each project's environments override it by key.
- **The active environment** is never written into the project, nor is anything else specific to your Mac.

## Variables

- **Reference** one as `{{name}}` in the URL, parameters, headers, bodies, and auth.
- **Built-ins** such as `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, and `{{$randomInt}}` generate a value on each send.
- **Pills.** Variables render as pills, red when undefined, and typing `{{` offers completion.
- **Secrets.** Mark a variable secret to keep its value in your Keychain instead of the project's files.

## Current values

- **Set by scripts.** When a script sets an environment or Global variable, the value is kept on your Mac as that environment's *current value*, which overrides the saved value by key. It never goes into the project, so running requests never changes `git status`.
- **Secret ones** stay in your Keychain and are masked wherever they show. A value is secret when its variable is, when the script asks for it, or when it contains another secret, such as `"Bearer " + token`.
- **Unset.** A script that unsets a variable hides its saved value until you reset it.
- **In the Environments sheet,** current values are listed under the variables. Reset one, or all of them, to use the saved values again, or Save as Value to make one the saved value everyone shares.
- **Editing a variable's saved value** in Reqling drops its current value, so your edit takes effect. Changes pulled from git leave current values alone.
