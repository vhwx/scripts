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
