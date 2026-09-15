# Contributing / Conventions

This repo is a personal script library. These conventions keep it browsable and consistent
as it grows.

## Folder structure

`<language>/<topic>/<script>` — e.g. `bash/networking/check-open-ports.sh`.

- Language folders are top-level (`bash/`, `powershell/`, `azure-cli/`, ...).
- Topic subfolders group scripts by purpose, not by date or project. Reuse an existing topic
  folder before creating a new one; only add a new topic when a script doesn't fit any existing
  one.
- Keep filenames descriptive and action-oriented: `disk-usage-report.sh`,
  `Get-DiskUsageReport.ps1`, `create-vm.sh`. Avoid generic names like `script1.sh` or `test.ps1`.

## Naming conventions per language

| Language     | File extension | Case style                    |
|--------------|-----------------|--------------------------------|
| Bash         | `.sh`           | `kebab-case.sh`                |
| PowerShell   | `.ps1`          | `PascalCase-Verb-Noun.ps1` (approved PowerShell verbs, e.g. `Get-`, `New-`, `Remove-`) |
| Azure CLI    | `.sh`           | `kebab-case.sh` (same as Bash) |

## Script headers

Every script starts with a header comment. Use the templates in [`templates/`](templates/) as
a starting point:

- `templates/bash-template.sh`
- `templates/powershell-template.ps1`

Required fields: **Description**, **Usage**, **Requirements**, **Author**, **Date**.

Azure CLI scripts additionally note the **required `az` extensions or subscription/permissions**
in the Requirements field.

## Documentation index

Each language folder has its own `README.md` listing the scripts it contains, one line per
script, grouped by topic subfolder. When you add a script, add a matching entry there.

## Style

- Scripts should fail loudly: use `set -euo pipefail` in Bash and `$ErrorActionPreference = "Stop"`
  in PowerShell, unless there's a documented reason not to.
- Prefer parameters/flags over hardcoded values (subscription IDs, paths, resource names) so
  scripts are reusable as examples, not one-offs.
- No secrets or credentials committed — use placeholders (e.g. `<subscription-id>`) and
  environment variables/prompts instead.
