# GraphQL

A GraphQL body's query editor knows the API's schema. `{{variables}}` inside the query are left alone.

## Editing

- **Completion** as you type, or on ⌃Space (or ⌥Esc, or Edit ▸ Show Completions) anywhere in the query: fields of the enclosing type, arguments, enum values, variables, directives, and fragments.
- **Descriptions** of whatever the pointer rests on.
- **Checking.** Misspelled fields, missing required arguments, type mismatches, and deprecated usage are underlined, with a menu of the problems above the query.

## Schema source

Chosen in the **Schema** row:

- **Introspection** is sent to the request's URL, with its own headers, auth, and TLS settings, as soon as the request opens. It's cached on this Mac per endpoint, so the schema is there at once next time. The row says how old it is; reload to ask the server again.
- **A schema file**, for servers that turn introspection off: SDL (`.graphql`, `.graphqls`, `.gql`) or a saved introspection result (`.json`).
  - A file inside the project's folder or repository is stored relative to it.
  - For one elsewhere, Reqling asks whether to share its path or remember it on this Mac only.

## Schema browser

- **Request ▸ Show GraphQL Schema** (⌥⌘0) browses the schema in the inspector beside the request:
  - the root types, then every type by kind;
  - a filter over every type and field;
  - each type's fields, arguments, defaults, deprecations, and where it is used, with every type a click away.
- **The inspector** shows or hides from the toolbar's inspector button or **View ▸ Show Inspector** (⌥⌘I), without switching between History and Schema.
