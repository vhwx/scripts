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
  request's source (the "IP configured in JIT policy" option in the portal), refusing
  to request access for any port still set to `*` (Any). Supports `--input-file` (see
  [`jit/vms.example.csv`](jit/vms.example.csv), one
  `subscription,resource-group,vm-name[,use-file-ip-ranges]` entry per line) to target
  VMs across scopes, or `--vm-names` for a single subscription/resource group. The
  input file may also declare a shared `ip-ranges: cidr[,cidr...]` collection (also
  never `*`) that individual rows opt into via the 4th column, overriding the port's
  JIT-configured ranges for that request only. `--configure` creates/updates a VM's
  JIT policy with a standard collection of allowed source IP ranges (via
  `--ip-ranges`, which also cannot be `*`) and a maximum request duration. Supports
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
