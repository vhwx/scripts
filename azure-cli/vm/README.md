# create-vm.sh

Creates a resource group and a Linux VM with SSH key authentication.

## Quickstart

```
./create-vm.sh my-rg my-vm westeurope
```

Requires `az login` and Contributor on the target subscription. Run
`az account set --subscription <subscription-id>` first if you have more than one.
