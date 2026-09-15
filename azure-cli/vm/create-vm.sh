#!/usr/bin/env bash
#
# Script:       create-vm.sh
# Description:  Creates a resource group and a Linux VM with SSH key authentication.
# Usage:        ./create-vm.sh <resource-group> <vm-name> <location>
# Requirements: az CLI logged in (`az login`), Contributor role on the target subscription.
#               Run `az account set --subscription <subscription-id>` first if you have
#               multiple subscriptions.
# Author:       example
# Date:         2026-09-15

set -euo pipefail

resource_group="${1:?Usage: ./create-vm.sh <resource-group> <vm-name> <location>}"
vm_name="${2:?Usage: ./create-vm.sh <resource-group> <vm-name> <location>}"
location="${3:-westeurope}"

az group create \
  --name "$resource_group" \
  --location "$location"

az vm create \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --image Ubuntu2204 \
  --admin-username azureuser \
  --generate-ssh-keys
