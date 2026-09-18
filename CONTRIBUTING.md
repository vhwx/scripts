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

## Documentation

Each script gets its own `README.md` in the same folder, with a short description and a
Quickstart usage example (see `azure-cli/jit/README.md` or `bash/system/README.md`). Each
language folder's `README.md` is just an index linking to those — add an entry there when you
add a script.

## Style

- Scripts should fail loudly: use `set -euo pipefail` in Bash and `$ErrorActionPreference = "Stop"`
  in PowerShell, unless there's a documented reason not to.
- Prefer parameters/flags over hardcoded values (subscription IDs, paths, resource names) so
  scripts are reusable as examples, not one-offs.
- No secrets or credentials committed — use placeholders (e.g. `<subscription-id>`) and
  environment variables/prompts instead.

## Linting

CI runs linters automatically on pull requests and pushes that touch scripts:

- **Bash / Azure CLI** (`bash/**/*.sh`, `azure-cli/**/*.sh`, `templates/**/*.sh`): checked with
  [ShellCheck](https://www.shellcheck.net/) (`.github/workflows/shellcheck.yml`). Run it locally
  with `shellcheck path/to/script.sh`.
- **PowerShell** (`powershell/**/*.ps1`, `templates/**/*.ps1`): checked with
  [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
  (`.github/workflows/psscriptanalyzer.yml`). Run it locally with
  `Invoke-ScriptAnalyzer -Path path/to/script.ps1`.

Fix reported warnings/errors before merging.
