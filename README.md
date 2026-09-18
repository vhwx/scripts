# scripts

Personal library of example scripts and automations — Bash, PowerShell, Azure CLI, and more.

## Structure

```
<language>/<topic>/<script>
```

- [`bash/`](bash/README.md) — Bash / POSIX shell
- [`powershell/`](powershell/README.md) — cross-platform PowerShell
- [`azure-cli/`](azure-cli/README.md) — `az` CLI examples
- [`templates/`](templates/) — starter templates

Each script has its own README with usage examples, next to the script. Each language folder
has an index README linking to them.

## Adding a script

1. Copy the matching template from `templates/`.
2. Place it in `<language>/<topic>/`.
3. Add a README next to it with a Quickstart example.
4. Link it from that language folder's `README.md`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for naming and header conventions.
