# Projects

A project is a folder of small JSON files, so it diffs cleanly and can live in your API's own git repository.

```
My API.reqling/
  project.json
  environments/default.json
  environments/staging.json
  requests/users/_folder.json
  requests/users/list-users.json
```

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
