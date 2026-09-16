#!/usr/bin/env bash
#
# Script:       az-jit-request.sh
# Description:  Requests (or configures) Microsoft Defender for Cloud just-in-time (JIT)
#               VM access for SSH (22) and/or RDP (3389) on a given set of virtual
#               machines, which may span multiple subscriptions and resource groups in
#               a single run. Mirrors the Azure Portal's VM "Connect > Request access"
#               flow via the ARM REST API: it reads each VM's existing JIT policy, uses
#               the source IP ranges already configured on that policy (the "JIT
#               configured IPs" option in the portal's Source IP address field) as the
#               allowed source for the access request, and refuses to request access
#               for any port still configured with "*" (Any) — that source setting must
#               be a real, restricted set of IP ranges. Use --configure to create/update
#               a VM's JIT policy with that standard collection of IP ranges in the
#               first place.
# Usage:        ./az-jit-request.sh --subscription <id> --resource-group <rg> \
#                   --vm-names vm1,vm2 [--ports 22,3389] [--duration PT1H]
#               ./az-jit-request.sh --input-file vms.csv --dry-run
#               ./az-jit-request.sh --subscription <id> --resource-group <rg> \
#                   --vm-names vm1,vm2 --configure \
#                   --ip-ranges 203.0.113.0/24,198.51.100.10/32 [--duration PT3H]
#               Run with -h/--help for the full option list.
# Requirements: Azure CLI (logged in via `az login`), jq. Microsoft Defender for Servers
#               Plan 2 must be enabled on every subscription involved, and the target
#               VMs must have a network security group (JIT does not support classic
#               VMs). Requesting access needs
#               Microsoft.Security/locations/jitNetworkAccessPolicies/*/read and
#               .../initiate/action on each resource group; --configure additionally
#               needs .../write and Microsoft.Compute/virtualMachines/write. Does not
#               assume a default subscription or change the current az CLI context —
#               every ARM call is made with an explicit subscription ID. Tested on
#               macOS and Linux with Bash 3.2+.
# Author:       Vegard Hoff Walmsness
# Date:         2026-09-16
#
# NOTE: This script intentionally uses `set -u` plus explicit `||` error checks rather
# than `set -e`, because several steps (missing VMs, unresolvable subscriptions,
# unconfigured ports, optional lookups) rely on inspecting exit codes/output without
# aborting the whole run.

set -u

API_VERSION="2020-01-01"
DEFAULT_PORTS="22,3389"
DEFAULT_PROTOCOL="*"
DEFAULT_POLICY_NAME="default"
DEFAULT_REQUEST_DURATION="PT1H"
DEFAULT_CONFIGURE_DURATION="PT3H"

SUBSCRIPTION=""
RESOURCE_GROUP=""
VM_NAMES_RAW=""
INPUT_FILE=""
PORTS_RAW="$DEFAULT_PORTS"
IP_RANGES_RAW=""
DURATION=""
DURATION_SET_BY_USER="false"
POLICY_NAME="$DEFAULT_POLICY_NAME"
PROTOCOL="$DEFAULT_PROTOCOL"
CONFIGURE="false"
AUTO_CONFIRM="false"
DRY_RUN="false"

PROGRAM_NAME=$(basename "$0")
TMP_DIR=""

usage() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} --subscription ID --resource-group RG --vm-names LIST [options]
  ${PROGRAM_NAME} --input-file PATH [options]

Options:
  --subscription ID|NAME  Subscription for --vm-names entries (required with --vm-names,
                            not used with --input-file — see "Input file format" below)
  --resource-group RG     Resource group for --vm-names entries (required with
                            --vm-names, not used with --input-file)
  --vm-names LIST         Comma-separated VM names within --subscription/--resource-group,
                            e.g. vm1,vm2. Mutually exclusive with --input-file.
  --input-file PATH       Batch mode: one "subscription,resource-group,vm-name" line per
                            entry instead of --vm-names/--subscription/--resource-group.
                            Lets a single run span multiple subscriptions and resource
                            groups. See "Input file format" below.
  --ports LIST            Comma-separated TCP ports, default: ${DEFAULT_PORTS}
  --duration ISO8601      Request mode: requested access duration, default:
                            ${DEFAULT_REQUEST_DURATION}. Configure mode: maximum
                            allowed request duration, default: ${DEFAULT_CONFIGURE_DURATION}
  --policy-name NAME      JIT policy name, default: ${DEFAULT_POLICY_NAME}
  --configure             Create/update the JIT policy instead of requesting access
  --ip-ranges LIST        Configure mode only (required): comma-separated CIDRs/IPs to
                            set as the allowed source IPs, e.g.
                            203.0.113.0/24,198.51.100.10/32. Cannot be "*" — the whole
                            point of this script is to avoid "Any" as the source.
  --protocol PROTO        Configure mode only: port protocol, default: "*" (any)
  --yes                   Skip the confirmation prompt
  --dry-run               Show the request(s)/policy update(s) without submitting them
  -h, --help              Show this help

Request mode (default) reads each VM's existing JIT policy and reuses whichever source
IP ranges are already configured for the requested port(s) — this is the same as
selecting "IP configured in JIT policy" for the Source IP address field in the Azure
Portal's request-access dialog. Ports still configured with "*" (Any) are skipped with
an error; run --configure on them first.

Input file format (used with --input-file):
  One "subscription,resource-group,vm-name" entry per line. Blank lines and lines
  starting with # are ignored. "subscription" may be a subscription ID or display name.
  This is how a single run can target VMs across different subscriptions and resource
  groups; --subscription/--resource-group are not used in this mode.

    # subscription,resource-group,vm-name
    Example-Sandbox-Subscription,example-rg,web-01
    01b0eec7-4e50-47fb-9b3b-47706b34e504,other-rg,app-vm-01

Examples:
  ${PROGRAM_NAME} --subscription 00000000-0000-0000-0000-000000000000 \\
      --resource-group example-rg --vm-names web-01,web-02

  ${PROGRAM_NAME} --input-file vms.csv --ports 3389 --duration PT2H

  ${PROGRAM_NAME} --subscription my-sub --resource-group example-rg \\
      --vm-names web-01,web-02 --configure \\
      --ip-ranges 203.0.113.0/24,198.51.100.10/32 --duration PT3H
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*" >&2
}

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

# Splits a comma-separated list into one trimmed, non-empty item per line on stdout.
split_csv() {
    printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --subscription)
            [ "$#" -ge 2 ] || die "--subscription requires a value"
            SUBSCRIPTION="$2"
            shift 2
            ;;
        --resource-group)
            [ "$#" -ge 2 ] || die "--resource-group requires a value"
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --vm-names)
            [ "$#" -ge 2 ] || die "--vm-names requires a value"
            VM_NAMES_RAW="$2"
            shift 2
            ;;
        --input-file)
            [ "$#" -ge 2 ] || die "--input-file requires a value"
            INPUT_FILE="$2"
            shift 2
            ;;
        --ports)
            [ "$#" -ge 2 ] || die "--ports requires a value"
            PORTS_RAW="$2"
            shift 2
            ;;
        --ip-ranges)
            [ "$#" -ge 2 ] || die "--ip-ranges requires a value"
            IP_RANGES_RAW="$2"
            shift 2
            ;;
        --duration)
            [ "$#" -ge 2 ] || die "--duration requires a value"
            DURATION="$2"
            DURATION_SET_BY_USER="true"
            shift 2
            ;;
        --policy-name)
            [ "$#" -ge 2 ] || die "--policy-name requires a value"
            POLICY_NAME="$2"
            shift 2
            ;;
        --protocol)
            [ "$#" -ge 2 ] || die "--protocol requires a value"
            PROTOCOL="$2"
            shift 2
            ;;
        --configure)
            CONFIGURE="true"
            shift
            ;;
        --yes)
            AUTO_CONFIRM="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

if [ -n "$VM_NAMES_RAW" ] && [ -n "$INPUT_FILE" ]; then
    die "Use either --vm-names or --input-file, not both."
fi

if [ -z "$VM_NAMES_RAW" ] && [ -z "$INPUT_FILE" ]; then
    die "Provide VMs via --vm-names or --input-file."
fi

if [ -n "$VM_NAMES_RAW" ]; then
    [ -n "$SUBSCRIPTION" ] || die "--subscription is required with --vm-names."
    [ -n "$RESOURCE_GROUP" ] || die "--resource-group is required with --vm-names."
fi

if [ -n "$INPUT_FILE" ]; then
    if [ -n "$SUBSCRIPTION" ] || [ -n "$RESOURCE_GROUP" ]; then
        die "--subscription/--resource-group are not used with --input-file; specify them per line instead (see -h)."
    fi
    [ -r "$INPUT_FILE" ] ||
        die "Input file not found or not readable: ${INPUT_FILE}"
fi

if [ "$DURATION_SET_BY_USER" != "true" ]; then
    if [ "$CONFIGURE" = "true" ]; then
        DURATION="$DEFAULT_CONFIGURE_DURATION"
    else
        DURATION="$DEFAULT_REQUEST_DURATION"
    fi
fi

case "$DURATION" in
    P*)
        ;;
    *)
        die "Duration must use ISO 8601 format, for example PT1H or PT30M."
        ;;
esac

if [ "$CONFIGURE" = "true" ]; then
    [ -n "$IP_RANGES_RAW" ] ||
        die "--configure requires --ip-ranges (a comma-separated list of CIDRs/IPs)."
fi

require_command az
require_command jq

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/az-jit.XXXXXX") ||
    die "Could not create temporary directory"

# --- Collect the requested port list --------------------------------------------

PORTS_FILE="${TMP_DIR}/ports.txt"
split_csv "$PORTS_RAW" > "$PORTS_FILE"
[ -s "$PORTS_FILE" ] || die "--ports produced an empty list."

while IFS= read -r PORT_ITEM; do
    case "$PORT_ITEM" in
        ''|*[!0-9]*)
            die "Invalid port: ${PORT_ITEM}"
            ;;
    esac
done < "$PORTS_FILE"

# --- Collect and validate the IP range list (configure mode only) ---------------

IP_RANGES_JSON='[]'

if [ "$CONFIGURE" = "true" ]; then
    IP_RANGES_FILE="${TMP_DIR}/ip-ranges.txt"
    split_csv "$IP_RANGES_RAW" > "$IP_RANGES_FILE"
    [ -s "$IP_RANGES_FILE" ] || die "--ip-ranges produced an empty list."

    while IFS= read -r RANGE_ITEM; do
        [ "$RANGE_ITEM" != "*" ] ||
            die "--ip-ranges cannot be \"*\" (Any). Provide one or more real CIDRs/IPs, for example 203.0.113.0/24."
    done < "$IP_RANGES_FILE"

    IP_RANGES_JSON=$(jq -Rn '[inputs]' < "$IP_RANGES_FILE")
fi

az account show >/dev/null 2>&1 ||
    die "Azure CLI is not logged in. Run: az login"

# --- Collect the VM specs: subscription, resource group, and VM name ------------
#
# Each row is "subscriptionRaw<TAB>resourceGroup<TAB>vmName". subscriptionRaw is
# whatever the user/file provided (ID or display name) and is resolved to a
# subscription ID below, once per distinct value.

SPECS_FILE="${TMP_DIR}/vm-specs.tsv"
: > "$SPECS_FILE"

if [ -n "$VM_NAMES_RAW" ]; then
    while IFS= read -r VM_NAME; do
        printf '%s\t%s\t%s\n' "$SUBSCRIPTION" "$RESOURCE_GROUP" "$VM_NAME" >> "$SPECS_FILE"
    done < <(split_csv "$VM_NAMES_RAW")
else
    LINE_NUMBER=0
    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE_NUMBER=$((LINE_NUMBER + 1))

        LINE=$(printf '%s' "$RAW_LINE" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$LINE" ] || continue

        LINE_SUBSCRIPTION=$(printf '%s' "$LINE" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_RG=$(printf '%s' "$LINE" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_VM=$(printf '%s' "$LINE" | cut -d',' -f3- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$LINE_SUBSCRIPTION" ] || [ -z "$LINE_RG" ] || [ -z "$LINE_VM" ]; then
            warn "Line ${LINE_NUMBER}: expected \"subscription,resource-group,vm-name\", got: ${RAW_LINE}"
            continue
        fi

        printf '%s\t%s\t%s\n' "$LINE_SUBSCRIPTION" "$LINE_RG" "$LINE_VM" >> "$SPECS_FILE"
    done < "$INPUT_FILE"
fi

sort -u "$SPECS_FILE" -o "$SPECS_FILE"
[ -s "$SPECS_FILE" ] || die "No VM entries were provided."

SPEC_COUNT=$(wc -l < "$SPECS_FILE" | tr -d ' ')
info "Resolving ${SPEC_COUNT} virtual machine(s)..."

# --- Resolve each distinct subscription to a subscription ID --------------------

SUB_CACHE_FILE="${TMP_DIR}/subscription-cache.tsv"
: > "$SUB_CACHE_FILE"

cut -f1 "$SPECS_FILE" | sort -u > "${TMP_DIR}/subscriptions.txt"

while IFS= read -r SUB_RAW; do
    SUB_ID=$(
        az account show \
            --subscription "$SUB_RAW" \
            --query id \
            --output tsv 2>/dev/null
    ) || true

    if [ -z "$SUB_ID" ]; then
        warn "Subscription is unavailable, skipping its VM(s): ${SUB_RAW}"
        continue
    fi

    printf '%s\t%s\n' "$SUB_RAW" "$SUB_ID" >> "$SUB_CACHE_FILE"
done < "${TMP_DIR}/subscriptions.txt"

# --- Resolve each VM to its resource ID and location -----------------------------

RESOLVED_FILE="${TMP_DIR}/resolved.tsv"
: > "$RESOLVED_FILE"

while IFS=$'\t' read -r SUB_RAW RG VM_NAME; do
    SUB_ID=$(awk -F '\t' -v subv="$SUB_RAW" '$1 == subv {print $2; exit}' "$SUB_CACHE_FILE")
    [ -n "$SUB_ID" ] || continue

    VM_INFO=$(
        az vm show \
            --subscription "$SUB_ID" \
            --resource-group "$RG" \
            --name "$VM_NAME" \
            --query "{id:id, location:location}" \
            --output json 2>/dev/null
    ) || true

    VM_ID=$(printf '%s' "${VM_INFO:-}" | jq -r '.id // empty' 2>/dev/null)
    VM_LOCATION=$(printf '%s' "${VM_INFO:-}" | jq -r '.location // empty' 2>/dev/null)

    if [ -z "$VM_ID" ] || [ -z "$VM_LOCATION" ]; then
        warn "VM not found in subscription '${SUB_RAW}', resource group '${RG}': ${VM_NAME}"
        continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$VM_NAME" "$VM_ID" "$VM_LOCATION" "$SUB_ID" "$RG" "$SUB_RAW" >> "$RESOLVED_FILE"
done < "$SPECS_FILE"

[ -s "$RESOLVED_FILE" ] ||
    die "None of the requested VMs could be resolved."

# --- Build the plan, one (subscription, resource group, location) group at a time -

PLAN_FILE="${TMP_DIR}/plan.jsonl"
: > "$PLAN_FILE"
SKIPPED_COUNT=0

GROUPS_FILE="${TMP_DIR}/groups.tsv"
cut -f3,4,5 "$RESOLVED_FILE" | sort -u > "$GROUPS_FILE"

while IFS=$'\t' read -r LOCATION SUB_ID RG; do
    POLICY_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Security/locations/${LOCATION}/jitNetworkAccessPolicies/${POLICY_NAME}?api-version=${API_VERSION}"

    POLICY_FILE="${TMP_DIR}/policy-${SUB_ID}-${RG}-${LOCATION}.json"

    if az rest --method GET --uri "$POLICY_URI" --output json > "$POLICY_FILE" 2>/dev/null; then
        POLICY_EXISTS="true"
    else
        POLICY_EXISTS="false"
        echo '{"properties":{"virtualMachines":[]}}' > "$POLICY_FILE"
    fi

    awk -F '\t' -v loc="$LOCATION" -v subv="$SUB_ID" -v rg="$RG" \
        '$3 == loc && $4 == subv && $5 == rg {print $1"\t"$2"\t"$6}' \
        "$RESOLVED_FILE" > "${TMP_DIR}/group-vms.tsv"

    if [ "$CONFIGURE" = "true" ]; then
        while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW; do
            printf '%s\n' \
                "$(jq -nc \
                    --arg id "$VM_ID" \
                    --arg name "$VM_NAME" \
                    --arg location "$LOCATION" \
                    --arg subscriptionId "$SUB_ID" \
                    --arg subscriptionDisplay "$SUB_RAW" \
                    --arg resourceGroup "$RG" \
                    --arg protocol "$PROTOCOL" \
                    --arg duration "$DURATION" \
                    --slurpfile ports "$PORTS_FILE" \
                    --argjson ipRanges "$IP_RANGES_JSON" \
                    '
                    {
                      vmName: $name,
                      id: $id,
                      location: $location,
                      subscriptionId: $subscriptionId,
                      subscriptionDisplay: $subscriptionDisplay,
                      resourceGroup: $resourceGroup,
                      ports: [
                        $ports[] as $p |
                        {
                          number: $p,
                          protocol: $protocol,
                          allowedSourceAddressPrefixes: $ipRanges,
                          maxRequestAccessDuration: $duration
                        }
                      ]
                    }
                    ')" >> "$PLAN_FILE"
        done < "${TMP_DIR}/group-vms.tsv"
    else
        if [ "$POLICY_EXISTS" != "true" ]; then
            while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW; do
                warn "No JIT policy '${POLICY_NAME}' found for VM '${VM_NAME}' (subscription ${SUB_RAW}, resource group ${RG}). Run with --configure first."
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            done < "${TMP_DIR}/group-vms.tsv"
            continue
        fi

        while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW; do
            VM_PORTS_FILE="${TMP_DIR}/vm-ports.json"
            jq -c \
                --arg id "$VM_ID" \
                '(.properties.virtualMachines // []) | map(select(.id == $id)) | .[0].ports // []' \
                "$POLICY_FILE" > "$VM_PORTS_FILE"

            while IFS= read -r REQ_PORT; do
                PORT_CONFIG=$(
                    jq -c --argjson port "$REQ_PORT" \
                        'map(select(.number == $port)) | .[0] // empty' \
                        "$VM_PORTS_FILE"
                )

                if [ -z "$PORT_CONFIG" ]; then
                    warn "VM '${VM_NAME}': port ${REQ_PORT} is not configured for JIT access. Run with --configure first."
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                    continue
                fi

                PREFIXES=$(
                    printf '%s' "$PORT_CONFIG" | jq -c '
                        if (.allowedSourceAddressPrefixes // []) != []
                        then .allowedSourceAddressPrefixes
                        elif (.allowedSourceAddressPrefix // "") != ""
                        then [.allowedSourceAddressPrefix]
                        else []
                        end
                    '
                )

                HAS_WILDCARD=$(printf '%s' "$PREFIXES" | jq -r 'map(select(. == "*")) | length')

                if [ "$PREFIXES" = "[]" ] || [ "$HAS_WILDCARD" != "0" ]; then
                    warn "VM '${VM_NAME}': port ${REQ_PORT} is configured with source IP \"*\" (Any). Refusing to request access — run --configure with real --ip-ranges first."
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                    continue
                fi

                jq -nc \
                    --arg id "$VM_ID" \
                    --arg name "$VM_NAME" \
                    --arg location "$LOCATION" \
                    --arg subscriptionId "$SUB_ID" \
                    --arg subscriptionDisplay "$SUB_RAW" \
                    --arg resourceGroup "$RG" \
                    --arg duration "$DURATION" \
                    --argjson port "$REQ_PORT" \
                    --argjson prefixes "$PREFIXES" \
                    '
                    {
                      vmName: $name,
                      id: $id,
                      location: $location,
                      subscriptionId: $subscriptionId,
                      subscriptionDisplay: $subscriptionDisplay,
                      resourceGroup: $resourceGroup,
                      ports: [
                        {
                          number: $port,
                          allowedSourceAddressPrefixes: $prefixes,
                          duration: $duration
                        }
                      ]
                    }
                    ' >> "$PLAN_FILE"
            done < "$PORTS_FILE"
        done < "${TMP_DIR}/group-vms.tsv"
    fi
done < "$GROUPS_FILE"

PLAN_COUNT=$(wc -l < "$PLAN_FILE" | tr -d ' ')

if [ "$PLAN_COUNT" -eq 0 ]; then
    die "Nothing to do: no VM/port combinations remained after validation."
fi

# --- Show the plan and ask for confirmation --------------------------------------

info ""
if [ "$CONFIGURE" = "true" ]; then
    info "Configure plan (${PLAN_COUNT} VM(s), ${SKIPPED_COUNT} skipped):"
else
    info "Request plan (${PLAN_COUNT} VM/port entr(y/ies), ${SKIPPED_COUNT} skipped):"
fi
info ""

while IFS= read -r PLAN_LINE; do
    P_NAME=$(printf '%s' "$PLAN_LINE" | jq -r '.vmName')
    P_SUB=$(printf '%s' "$PLAN_LINE" | jq -r '.subscriptionDisplay')
    P_RG=$(printf '%s' "$PLAN_LINE" | jq -r '.resourceGroup')

    if [ "$CONFIGURE" = "true" ]; then
        P_PORTS=$(printf '%s' "$PLAN_LINE" | jq -r '[.ports[].number] | join(",")')
        info "  ${P_NAME} (${P_SUB}/${P_RG}): ports ${P_PORTS} -> source ${IP_RANGES_RAW}, max duration ${DURATION}"
    else
        P_PORT=$(printf '%s' "$PLAN_LINE" | jq -r '.ports[0].number')
        P_PREFIXES=$(printf '%s' "$PLAN_LINE" | jq -r '.ports[0].allowedSourceAddressPrefixes | join(",")')
        info "  ${P_NAME} (${P_SUB}/${P_RG}): port ${P_PORT} -> source ${P_PREFIXES}, duration ${DURATION}"
    fi
done < "$PLAN_FILE"

if [ "$DRY_RUN" = "true" ]; then
    info ""
    info "Dry run. No changes were submitted."
fi

if [ "$DRY_RUN" != "true" ] && [ "$AUTO_CONFIRM" != "true" ]; then
    if [ "$CONFIGURE" = "true" ]; then
        printf '\nConfigure JIT policy for these %s VM(s)? [y/N]: ' "$PLAN_COUNT" >&2
    else
        printf '\nRequest JIT access for these %s VM/port entr(y/ies)? [y/N]: ' "$PLAN_COUNT" >&2
    fi
    IFS= read -r CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) info "Aborted. No changes were submitted."; exit 0 ;;
    esac
fi

# --- Execute, one ARM call per (subscription, resource group, location) group ----

SUCCESS_COUNT=0
FAILURE_COUNT=0

while IFS=$'\t' read -r LOCATION SUB_ID RG; do
    GROUP_PLAN="${TMP_DIR}/group-plan-${SUB_ID}-${RG}-${LOCATION}.jsonl"
    jq -c --arg sub "$SUB_ID" --arg rg "$RG" --arg loc "$LOCATION" \
        'select(.subscriptionId == $sub and .resourceGroup == $rg and .location == $loc)' \
        "$PLAN_FILE" > "$GROUP_PLAN"
    [ -s "$GROUP_PLAN" ] || continue

    POLICY_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Security/locations/${LOCATION}/jitNetworkAccessPolicies/${POLICY_NAME}?api-version=${API_VERSION}"
    ERROR_LOG="${TMP_DIR}/error-${SUB_ID}-${RG}-${LOCATION}.log"

    if [ "$CONFIGURE" = "true" ]; then
        POLICY_FILE="${TMP_DIR}/policy-${SUB_ID}-${RG}-${LOCATION}.json"

        NEW_VMS_JSON=$(jq -s '.' "$GROUP_PLAN")

        MERGED_BODY=$(
            jq -n \
                --arg location "$LOCATION" \
                --argjson newVms "$NEW_VMS_JSON" \
                --slurpfile existing "$POLICY_FILE" \
                '
                (($existing[0].properties.virtualMachines) // []) as $existingVms
                | ($newVms | map(.id)) as $newIds
                | {
                    kind: "Basic",
                    location: $location,
                    properties: {
                      virtualMachines: (
                          ($existingVms | map(select((.id as $i | ($newIds | index($i))) | not)))
                          + ($newVms | map({id: .id, ports: .ports}))
                      )
                    }
                  }
                '
        )

        if [ "$DRY_RUN" = "true" ]; then
            printf 'PUT %s\n\n' "$POLICY_URI"
            printf '%s\n' "$MERGED_BODY" | jq .
            continue
        fi

        if az rest --method PUT --uri "$POLICY_URI" --body "$MERGED_BODY" --output none 2>"$ERROR_LOG"; then
            GROUP_VM_COUNT=$(printf '%s' "$NEW_VMS_JSON" | jq 'length')
            info "Configured JIT policy '${POLICY_NAME}' at ${RG}/${LOCATION} for ${GROUP_VM_COUNT} VM(s)."
            SUCCESS_COUNT=$((SUCCESS_COUNT + GROUP_VM_COUNT))
        else
            warn "Failed to configure JIT policy at ${RG}/${LOCATION}: $(cat "$ERROR_LOG")"
            FAILURE_COUNT=$((FAILURE_COUNT + $(printf '%s' "$NEW_VMS_JSON" | jq 'length')))
        fi
    else
        INITIATE_URI="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Security/locations/${LOCATION}/jitNetworkAccessPolicies/${POLICY_NAME}/initiate?api-version=${API_VERSION}"

        REQUEST_BODY=$(
            jq -s \
                '{
                   virtualMachines: map({
                     id: .id,
                     ports: [.ports[0]]
                   })
                 }' \
                "$GROUP_PLAN"
        )

        if [ "$DRY_RUN" = "true" ]; then
            printf 'POST %s\n\n' "$INITIATE_URI"
            printf '%s\n' "$REQUEST_BODY" | jq .
            continue
        fi

        RESPONSE_FILE="${TMP_DIR}/initiate-response-${SUB_ID}-${RG}-${LOCATION}.json"

        if az rest --method POST --uri "$INITIATE_URI" --body "$REQUEST_BODY" --output json > "$RESPONSE_FILE" 2>"$ERROR_LOG"; then
            jq -r '.virtualMachines[] as $vm | $vm.ports[] | "  \($vm.id | split("/") | last): port \(.number) -> \(.status // "Initiating") (\(.endTimeUtc // "n/a"))"' "$RESPONSE_FILE" >&2
            SUCCESS_COUNT=$((SUCCESS_COUNT + $(jq '[.virtualMachines[].ports[]] | length' "$RESPONSE_FILE")))
        else
            warn "Failed to request JIT access at ${RG}/${LOCATION}: $(cat "$ERROR_LOG")"
            FAILURE_COUNT=$((FAILURE_COUNT + $(wc -l < "$GROUP_PLAN" | tr -d ' ')))
        fi
    fi
done < "$GROUPS_FILE"

if [ "$DRY_RUN" = "true" ]; then
    exit 0
fi

info ""
info "Done: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed."

[ "$FAILURE_COUNT" -eq 0 ] || exit 1

exit 0
