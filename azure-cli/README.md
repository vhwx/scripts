# Azure CLI

`az` CLI command examples, wrapped as Bash scripts, organized by Azure service/topic.

These follow the same conventions as [`bash/`](../bash/README.md) (see
[`templates/bash-template.sh`](../templates/bash-template.sh) and the root
[CONTRIBUTING.md](../CONTRIBUTING.md)), with one addition: the **Requirements** field in the
header must note any required `az` extensions, subscription context, or role assignments.

Scripts should use placeholders (e.g. `<subscription-id>`, `<resource-group>`) rather than
hardcoded values, and should not assume a default subscription is already set — call
`az account set --subscription <subscription-id>` explicitly or accept it as a parameter.

## Index

### vm

- [`vm/create-vm.sh`](vm/create-vm.sh) — Creates a resource group and a Linux VM with SSH key
  auth.

### storage

_No scripts yet._

### jit

- [`jit/az-jit-request.sh`](jit/az-jit-request.sh) — Requests Microsoft Defender for
  Cloud just-in-time (JIT) VM access for SSH (22) and/or RDP (3389) on a given set of
  virtual machines, which may span multiple subscriptions and resource groups in a
  single run. Reuses each VM's already configured JIT source IP ranges as the
  request's source (the "IP configured in JIT policy" option in the portal), including
  `*` (Any) if that's genuinely what a policy you don't control allows for a port.
  Supports `--input-file` (see
  [`jit/vms.example.csv`](jit/vms.example.csv), one
  `subscription,resource-group,vm-name[,use-file-ip-ranges][,ports]` entry per line)
  to target VMs across scopes, or `--vm-names` for a single subscription/resource
  group. The input file may also declare a shared `ip-ranges: cidr[,cidr...]`
  collection (also never `*`) that individual rows opt into via the 4th column,
  overriding the port's JIT-configured ranges for that request only — including
  narrowing a `*` policy port down to a real range, since Azure always accepts a
  specific range as a valid subset of `*` — and each row may override which port(s)
  it targets via a semicolon-separated 5th column (e.g. `22;3389`), falling back to
  the global `--ports` list otherwise. `--configure` creates/updates a VM's JIT policy
  with a standard collection of allowed source IP
  ranges (via `--ip-ranges`, which also cannot be `*`, or falling back to the input
  file's `ip-ranges:` directive if `--ip-ranges` isn't given) and a maximum request
  duration. The requested `--duration` is automatically capped down to a port's own
  configured maximum when it's shorter, since Azure rejects any request whose IP
  ranges or duration aren't a subset of the policy. Supports
  `--dry-run` to preview requests/policy updates without submitting them.

### pim

- [`pim/az-pim-activate.sh`](pim/az-pim-activate.sh) — Interactively lists the signed-in
  user's eligible Azure PIM resource-role assignments (direct and group-derived) tenant-wide
  in a single call — mirroring the Azure Portal's "My roles > Azure resources" view, including
  subscriptions the caller has no standing access to — and submits a self-activation request
  with a prefilled default justification. Uses `fzf` for a searchable menu when available,
  falls back to a numbered menu otherwise. Supports `--subscription` to filter the list,
  `--dry-run` to preview the activation request without submitting it, and `--input-file`
  (see [`pim/roles.example.csv`](pim/roles.example.csv)) to batch-activate a list of
  role/scope pairs with one shared duration (default `PT4H`) and justification.
