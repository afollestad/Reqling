## Repo-Local Workflows

- **Keep workflow homes separate.** Store capability workflows under `.agents/skills`; store review, audit, and check workflows under `.agents/checks`.
- **Expose workflows through symlinks.** `.claude/checks` and `.codex/checks` link to `.agents/checks`. Add `.claude/skills` and `.codex/skills` links to `.agents/skills` together with the first skill, so no link dangles.
- **Keep workflows concise.** Put only agent-facing workflow details in workflow Markdown files, within the root `## Keep Guidance Current` budget; keep human workflow docs in `README.md`.
- **Use the self-review check.** For self reviews or audits, follow `.agents/checks/self-review.md`.
- **Protect secrets.** Never commit signing certificates, API keys, passwords, or base64 secret values.
