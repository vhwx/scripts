# scripts

A personal library of example scripts and automations across languages and platforms —
shell, PowerShell, Azure CLI, and more as they're added.

## Purpose

This repo is a reference library, not a deployable project. Each script should be:

- **Self-contained** — runnable on its own with minimal setup, or clearly document its dependencies.
- **Documented** — a header comment explaining what it does, how to run it, and any prerequisites.
- **Categorized** — grouped by topic (e.g. `system`, `networking`, `vm`, `storage`) within its language folder.

## Structure

Scripts are organized by language/platform at the top level, then by topic:

```
scripts/
├── bash/           # Bash / POSIX shell scripts
│   ├── system/
│   └── networking/
├── powershell/      # PowerShell scripts (cross-platform pwsh)
│   ├── system/
│   └── networking/
├── azure-cli/       # az CLI command examples, wrapped in shell scripts
│   ├── vm/
│   └── storage/
└── templates/       # Starter templates with the required header format
```

New languages/platforms (e.g. `python/`, `terraform/`, `graphql/`) get their own top-level
folder following the same `<language>/<topic>/<script>` pattern. See each language folder's
own `README.md` for language-specific conventions.

## Adding a new script

1. Pick (or create) the topic subfolder under the relevant language folder.
2. Copy the matching starter from `templates/`.
3. Fill in the header (synopsis, usage, requirements, author, date).
4. Add an entry to that language folder's `README.md` index.

See [CONTRIBUTING.md](CONTRIBUTING.md) for naming and documentation conventions.
