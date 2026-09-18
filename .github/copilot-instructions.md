# Copilot instructions

This repo is a personal **library of example scripts and automations** across languages and
platforms (Bash, PowerShell, Azure CLI, and more as they're added). It is a reference
collection, not a deployable application — there is no build, test, or lint pipeline.

## Structure

Scripts live at `<language>/<topic>/<script>`:

```
bash/<topic>/*.sh
powershell/<topic>/*.ps1
azure-cli/<topic>/*.sh
templates/            # starter templates with the required header format
```

Each script has its own `README.md` next to it, with a short description and a Quickstart
usage example. Each language folder has its own `README.md` that links to those, grouped by
topic subfolder. A new language/platform gets its own top-level folder following the same
`<language>/<topic>/<script>` pattern and its own `README.md` index.

## Conventions (see CONTRIBUTING.md for full detail)

- **Filenames**: `kebab-case.sh` for Bash and Azure CLI scripts; `PascalCase-Verb-Noun.ps1`
  (approved PowerShell verbs) for PowerShell.
- **Headers**: every script starts with a comment block documenting Description, Usage,
  Requirements, Author, and Date. Copy from `templates/bash-template.sh` or
  `templates/powershell-template.ps1` rather than writing headers from scratch.
- **Error handling**: Bash scripts use `set -euo pipefail`; PowerShell scripts set
  `$ErrorActionPreference = "Stop"`.
- **No hardcoded secrets or environment-specific values** — use placeholders
  (e.g. `<subscription-id>`, `<resource-group>`) and parameters/flags instead.
- **Azure CLI scripts** additionally document required `az` extensions, subscription context,
  or role assignments in the Requirements header field, and must not assume a default
  subscription — set it explicitly with `az account set --subscription <subscription-id>`.

## When adding a script

1. Place it under the correct `<language>/<topic>/` folder (reuse an existing topic before
   creating a new one).
2. Base it on the matching template in `templates/`.
3. Add a `README.md` next to it with a Quickstart example.
4. Link it from that language folder's `README.md` index.
