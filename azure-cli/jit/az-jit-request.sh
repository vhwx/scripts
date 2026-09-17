#!/usr/bin/env bash
#
# Script:       az-jit-request.sh
# Description:  Requests (or configures) Microsoft Defender for Cloud just-in-time (JIT)
#               VM access for SSH (22) and/or RDP (3389) on a given set of virtual
#               machines, which may span multiple subscriptions and resource groups in
#               a single run. Mirrors the Azure Portal's VM "Connect > Request access"
#               flow via the ARM REST API: by default it reads each VM's existing JIT
#               policy and reuses the source IP ranges already configured on that
#               policy (the "JIT configured IPs" option in the portal's Source IP
#               address field) as the allowed source for the access request, including
#               "*" (Any) if that's genuinely what the policy allows for a port you
#               don't control the configuration of. An --input-file may also declare a
#               standard collection of IP ranges once at the top (an "ip-ranges:"
#               directive) and let individual VM rows opt into using it for their
#               request instead of the policy's own ranges — this also lets you narrow
#               a "*" (Any) policy port down to a real range you choose, since Azure
#               always accepts a specific range as a valid subset of "*". Each
#               input-file row may also override which port(s) it requests, so a
#               single batch can mix SSH-only, RDP-only, and both-port targets. Use
#               --configure to create/update a VM's JIT policy with a standard
#               collection of IP ranges in the first place (this mode still refuses to
#               set the policy itself to "*", since you control it directly here); the
#               same --input-file "ip-ranges:" directive also doubles as the default
#               --ip-ranges for --configure when it isn't given on the command line.
#               The requested duration is likewise automatically capped down to a
#               port's own configured maximum when needed, since Azure rejects any
#               request whose IP ranges or duration aren't a subset of the policy.
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
  --ports LIST            Comma-separated TCP ports, default: ${DEFAULT_PORTS}. Can be
                            overridden per row in --input-file (see below)
  --duration ISO8601      Request mode: requested access duration, default:
                            ${DEFAULT_REQUEST_DURATION}, automatically capped down to
                            a port's own configured maximum if that's shorter.
                            Configure mode: maximum
                            allowed request duration, default: ${DEFAULT_CONFIGURE_DURATION}
  --policy-name NAME      JIT policy name, default: ${DEFAULT_POLICY_NAME}
  --configure             Create/update the JIT policy instead of requesting access
  --ip-ranges LIST        Configure mode only: comma-separated CIDRs/IPs to set as the
                            allowed source IPs, e.g. 203.0.113.0/24,198.51.100.10/32.
                            Cannot be "*" — the whole point of this script is to avoid
                            "Any" as the source. Required unless --input-file declares
                            an ip-ranges: directive, which is used as the fallback.
  --protocol PROTO        Configure mode only: port protocol, default: "*" (any)
  --yes                   Skip the confirmation prompt
  --dry-run               Show the request(s)/policy update(s) without submitting them
  -h, --help              Show this help

Request mode (default) reads each VM's existing JIT policy and reuses whichever source
IP ranges are already configured for the requested port(s) — this is the same as
selecting "IP configured in JIT policy" for the Source IP address field in the Azure
Portal's request-access dialog. If a port is configured with "*" (Any) — for example
on a VM you don't control the JIT policy of — the request is still submitted using
"*" as-is (with a warning), or you can opt the row into the input file's ip-ranges
directive (see below) to narrow the request down to a real range instead; Azure always
accepts a specific range as a valid subset of a "*" policy. The requested --duration
is likewise automatically capped down to a port's own maxRequestAccessDuration (with
a warning) if it's shorter than the requested/default duration, since Azure otherwise
rejects the whole request as not being a subset of the policy.

Input file format (used with --input-file):
  One "subscription,resource-group,vm-name[,use-file-ip-ranges][,ports]" entry per
  line. Blank lines and lines starting with # are ignored. "subscription" may be a
  subscription ID or display name. This is how a single run can target VMs across
  different subscriptions and resource groups; --subscription/--resource-group are
  not used in this mode.

  An optional "ip-ranges: cidr[,cidr...]" directive line (anywhere in the file, but
  conventionally at the top) declares a standard collection of source IP ranges for
  the file. It cannot be "*". Set the 4th column to yes/true/1 on a VM row to use that
  collection as the request's source IP instead of the port's JIT-configured ranges;
  leave it blank (or no/false/0) to keep using the JIT-configured ranges. A row that
  opts in without a directive present falls back to the JIT-configured ranges with a
  warning. In --configure mode, this directive also doubles as the default for
  --ip-ranges: if --ip-ranges isn't given on the command line, the directive's ranges
  are used for every VM in the file (--ip-ranges, if given, always takes priority).

  An optional 5th column overrides which port(s) that row requests/configures, as a
  semicolon-separated list, e.g. "22" or "22;3389" (semicolons, not commas, since
  commas are already the field separator). Leave it blank to use the global --ports
  list. This lets a single input file mix SSH-only, RDP-only, and both-port targets.

    # Standard collection of IPs to request access from, shared by rows below
    ip-ranges: 203.0.113.0/24,198.51.100.10/32

    # subscription,resource-group,vm-name,use-file-ip-ranges,ports
    Example-Sandbox-Subscription,example-rg,web-01,yes,22
    Example-Sandbox-Subscription,example-rg,web-02,,3389
    01b0eec7-4e50-47fb-9b3b-47706b34e504,other-rg,app-vm-01,,22;3389

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

# Splits a semicolon-separated list (used for the input file's per-row "ports"
# column, since commas are already the field delimiter there) the same way.
split_semi() {
    printf '%s' "$1" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# Converts a (limited) ISO 8601 duration such as "PT1H", "PT30M", "PT1H30M", or "P1D"
# into a whole number of seconds on stdout. Returns non-zero (no output) if the value
# doesn't match the supported subset (date/time designators D/H/M/S only — no
# weeks/months/years, which JIT durations don't use).
iso8601_duration_to_seconds() {
    local dur="$1"
    if [[ "$dur" =~ ^P(([0-9]+)D)?(T(([0-9]+)H)?(([0-9]+)M)?(([0-9]+)S)?)?$ ]]; then
        local days="${BASH_REMATCH[2]:-0}"
        local hours="${BASH_REMATCH[5]:-0}"
        local minutes="${BASH_REMATCH[7]:-0}"
        local seconds="${BASH_REMATCH[9]:-0}"
        echo $(( days * 86400 + hours * 3600 + minutes * 60 + seconds ))
        return 0
    fi
    return 1
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

# --- Collect the IP range list (configure mode only; validated further below, once
# the input file's optional "ip-ranges:" directive has also been read, so --configure
# can fall back to it when --ip-ranges isn't given on the command line) ------------

IP_RANGES_JSON='[]'

az account show >/dev/null 2>&1 ||
    die "Azure CLI is not logged in. Run: az login"

# --- Collect the VM specs: subscription, resource group, and VM name ------------
#
# Each row is "subscriptionRaw<TAB>resourceGroup<TAB>vmName<TAB>useFileRanges<TAB>linePorts".
# subscriptionRaw is whatever the user/file provided (ID or display name) and is
# resolved to a subscription ID below, once per distinct value. useFileRanges is
# "true"/"false", set from the input file's optional per-row 4th column (see below);
# --vm-names entries always get "false" since there is no file-level ip-ranges
# directive outside of --input-file. linePorts is a semicolon-separated list of ports
# from the input file's optional per-row 5th column, or "" to use the global --ports
# list; --vm-names entries always get "" since ports are already given via --ports.

SPECS_FILE="${TMP_DIR}/vm-specs.tsv"
: > "$SPECS_FILE"

# File-level "ip-ranges:" directive (--input-file only): a standard collection of
# source IP ranges that individual VM rows can opt into using for their JIT request
# instead of the port's own JIT-configured ranges.
FILE_IP_RANGES_JSON='[]'
FILE_IP_RANGES_RAW=""
FILE_IP_RANGES_SET="false"

if [ -n "$VM_NAMES_RAW" ]; then
    while IFS= read -r VM_NAME; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$SUBSCRIPTION" "$RESOURCE_GROUP" "$VM_NAME" "false" "" >> "$SPECS_FILE"
    done < <(split_csv "$VM_NAMES_RAW")
else
    LINE_NUMBER=0
    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE_NUMBER=$((LINE_NUMBER + 1))

        LINE=$(printf '%s' "$RAW_LINE" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$LINE" ] || continue

        case "$LINE" in
            [Ii][Pp]-[Rr][Aa][Nn][Gg][Ee][Ss]:*)
                if [ "$FILE_IP_RANGES_SET" = "true" ]; then
                    warn "Line ${LINE_NUMBER}: duplicate ip-ranges directive ignored."
                    continue
                fi

                DIRECTIVE_VALUE=$(printf '%s' "$LINE" | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                if [ -z "$DIRECTIVE_VALUE" ]; then
                    warn "Line ${LINE_NUMBER}: ip-ranges directive has no value, ignoring."
                    continue
                fi

                DIRECTIVE_RANGES_FILE="${TMP_DIR}/file-ip-ranges.txt"
                split_csv "$DIRECTIVE_VALUE" > "$DIRECTIVE_RANGES_FILE"

                if [ ! -s "$DIRECTIVE_RANGES_FILE" ]; then
                    warn "Line ${LINE_NUMBER}: ip-ranges directive produced an empty list, ignoring."
                    continue
                fi

                while IFS= read -r RANGE_ITEM; do
                    [ "$RANGE_ITEM" != "*" ] ||
                        die "Line ${LINE_NUMBER}: ip-ranges directive cannot be \"*\" (Any). Provide one or more real CIDRs/IPs."
                done < "$DIRECTIVE_RANGES_FILE"

                FILE_IP_RANGES_RAW="$DIRECTIVE_VALUE"
                FILE_IP_RANGES_JSON=$(jq -Rn '[inputs]' < "$DIRECTIVE_RANGES_FILE")
                FILE_IP_RANGES_SET="true"
                info "Input file ip-ranges directive: ${FILE_IP_RANGES_RAW}"
                continue
                ;;
        esac

        LINE_SUBSCRIPTION=$(printf '%s' "$LINE" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_RG=$(printf '%s' "$LINE" | cut -d',' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_VM=$(printf '%s' "$LINE" | cut -d',' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_USE_RANGE_RAW=$(printf '%s' "$LINE" | cut -d',' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        LINE_PORTS_RAW=$(printf '%s' "$LINE" | cut -d',' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$LINE_SUBSCRIPTION" ] || [ -z "$LINE_RG" ] || [ -z "$LINE_VM" ]; then
            warn "Line ${LINE_NUMBER}: expected \"subscription,resource-group,vm-name[,use-file-ip-ranges][,ports]\", got: ${RAW_LINE}"
            continue
        fi

        LINE_USE_FILE_RANGES="false"
        case "$LINE_USE_RANGE_RAW" in
            ''|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|0)
                ;;
            [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1)
                if [ "$FILE_IP_RANGES_SET" = "true" ]; then
                    LINE_USE_FILE_RANGES="true"
                else
                    warn "Line ${LINE_NUMBER}: VM '${LINE_VM}' requests the file's ip-ranges, but no ip-ranges directive was found; using JIT-configured ranges instead."
                fi
                ;;
            *)
                warn "Line ${LINE_NUMBER}: unrecognized ip-ranges indicator \"${LINE_USE_RANGE_RAW}\" for VM '${LINE_VM}' (expected yes/no); using JIT-configured ranges."
                ;;
        esac

        LINE_PORTS="$LINE_PORTS_RAW"
        if [ -n "$LINE_PORTS_RAW" ]; then
            LINE_PORTS_CHECK_FILE="${TMP_DIR}/line-ports-check.txt"
            split_semi "$LINE_PORTS_RAW" > "$LINE_PORTS_CHECK_FILE"

            if [ ! -s "$LINE_PORTS_CHECK_FILE" ]; then
                warn "Line ${LINE_NUMBER}: VM '${LINE_VM}' has an empty ports override, using --ports instead."
                LINE_PORTS=""
            else
                LINE_PORTS_INVALID="false"
                while IFS= read -r LINE_PORT_ITEM; do
                    case "$LINE_PORT_ITEM" in
                        ''|*[!0-9]*)
                            warn "Line ${LINE_NUMBER}: invalid port \"${LINE_PORT_ITEM}\" for VM '${LINE_VM}', using --ports instead."
                            LINE_PORTS_INVALID="true"
                            ;;
                    esac
                done < "$LINE_PORTS_CHECK_FILE"

                [ "$LINE_PORTS_INVALID" = "false" ] || LINE_PORTS=""
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$LINE_SUBSCRIPTION" "$LINE_RG" "$LINE_VM" "$LINE_USE_FILE_RANGES" "$LINE_PORTS" >> "$SPECS_FILE"
    done < "$INPUT_FILE"
fi

# --- Validate the IP range list now (configure mode only) -----------------------
#
# Deferred until here so that, with --input-file, --configure can fall back to the
# file's "ip-ranges:" directive when --ip-ranges wasn't given on the command line.

if [ "$CONFIGURE" = "true" ]; then
    if [ -z "$IP_RANGES_RAW" ] && [ "$FILE_IP_RANGES_SET" = "true" ]; then
        IP_RANGES_RAW="$FILE_IP_RANGES_RAW"
        info "--configure: no --ip-ranges given; using the input file's ip-ranges directive (${IP_RANGES_RAW})."
    fi

    [ -n "$IP_RANGES_RAW" ] ||
        die "--configure requires --ip-ranges (a comma-separated list of CIDRs/IPs), or an ip-ranges: directive in --input-file."

    IP_RANGES_FILE="${TMP_DIR}/ip-ranges.txt"
    split_csv "$IP_RANGES_RAW" > "$IP_RANGES_FILE"
    [ -s "$IP_RANGES_FILE" ] || die "--ip-ranges produced an empty list."

    while IFS= read -r RANGE_ITEM; do
        [ "$RANGE_ITEM" != "*" ] ||
            die "--ip-ranges cannot be \"*\" (Any). Provide one or more real CIDRs/IPs, for example 203.0.113.0/24."
    done < "$IP_RANGES_FILE"

    IP_RANGES_JSON=$(jq -Rn '[inputs]' < "$IP_RANGES_FILE")
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

while IFS=$'\t' read -r SUB_RAW RG VM_NAME USE_FILE_RANGES LINE_PORTS; do
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

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$VM_NAME" "$VM_ID" "$VM_LOCATION" "$SUB_ID" "$RG" "$SUB_RAW" "$USE_FILE_RANGES" "$LINE_PORTS" >> "$RESOLVED_FILE"
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
        '$3 == loc && $4 == subv && $5 == rg {print $1"\t"$2"\t"$6"\t"$7"\t"$8}' \
        "$RESOLVED_FILE" > "${TMP_DIR}/group-vms.tsv"

    if [ "$CONFIGURE" = "true" ]; then
        while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW USE_FILE_RANGES LINE_PORTS; do
            if [ -n "$LINE_PORTS" ]; then
                ROW_PORTS_FILE="${TMP_DIR}/row-ports.txt"
                split_semi "$LINE_PORTS" > "$ROW_PORTS_FILE"
            else
                ROW_PORTS_FILE="$PORTS_FILE"
            fi

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
                    --slurpfile ports "$ROW_PORTS_FILE" \
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
            while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW USE_FILE_RANGES LINE_PORTS; do
                warn "No JIT policy '${POLICY_NAME}' found for VM '${VM_NAME}' (subscription ${SUB_RAW}, resource group ${RG}). Run with --configure first."
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            done < "${TMP_DIR}/group-vms.tsv"
            continue
        fi

        while IFS=$'\t' read -r VM_NAME VM_ID SUB_RAW USE_FILE_RANGES LINE_PORTS; do
            VM_PORTS_FILE="${TMP_DIR}/vm-ports.json"
            jq -c \
                --arg id "$VM_ID" \
                '(.properties.virtualMachines // []) | map(select((.id | ascii_downcase) == ($id | ascii_downcase))) | .[0].ports // []' \
                "$POLICY_FILE" > "$VM_PORTS_FILE"

            if [ -n "$LINE_PORTS" ]; then
                ROW_PORTS_FILE="${TMP_DIR}/row-ports.txt"
                split_semi "$LINE_PORTS" > "$ROW_PORTS_FILE"
            else
                ROW_PORTS_FILE="$PORTS_FILE"
            fi

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

                if [ "$USE_FILE_RANGES" = "true" ]; then
                    # Row opted into the input file's "ip-ranges:" directive: use it
                    # as-is, regardless of what the policy itself has configured. Any
                    # specific range is a valid Azure-side subset of a "*" policy port,
                    # so this also works to narrow down access on VMs whose policy is
                    # intentionally left at "*" (Any).
                    PREFIXES="$FILE_IP_RANGES_JSON"
                else
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

                    if [ "$PREFIXES" = "[]" ]; then
                        warn "VM '${VM_NAME}': port ${REQ_PORT} has no source IP configured at all. Refusing to request access — run --configure first, or opt this row into the input file's ip-ranges directive."
                        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                        continue
                    fi

                    HAS_WILDCARD=$(printf '%s' "$PREFIXES" | jq -r 'map(select(. == "*")) | length')

                    if [ "$HAS_WILDCARD" != "0" ]; then
                        # The policy itself allows "*" (Any) for this port. We don't
                        # control that policy, so request access using it as-is
                        # (equivalent to selecting "IP configured in JIT policy" for a
                        # VM whose owner has chosen "*"); use the input file's
                        # ip-ranges directive on this row instead if you want to
                        # narrow the request down to a custom range.
                        warn "VM '${VM_NAME}': port ${REQ_PORT} is configured with source IP \"*\" (Any) in the JIT policy. Requesting access with \"*\" as-is — opt this row into the input file's ip-ranges directive to narrow it down instead."
                    fi
                fi

                # The requested duration must also be a subset of (i.e. not exceed)
                # the port's own maxRequestAccessDuration, or Azure rejects the whole
                # request as "not a subset of policy" — same rule as the source IP
                # ranges above, just for duration instead. Cap it down automatically
                # (with a warning) rather than failing outright, mirroring what the
                # Portal does by capping the selectable duration to the policy max.
                EFFECTIVE_DURATION="$DURATION"
                PORT_MAX_DURATION=$(printf '%s' "$PORT_CONFIG" | jq -r '.maxRequestAccessDuration // empty')

                if [ -n "$PORT_MAX_DURATION" ]; then
                    REQ_SECONDS=$(iso8601_duration_to_seconds "$DURATION") || REQ_SECONDS=""
                    MAX_SECONDS=$(iso8601_duration_to_seconds "$PORT_MAX_DURATION") || MAX_SECONDS=""

                    if [ -n "$REQ_SECONDS" ] && [ -n "$MAX_SECONDS" ] && [ "$REQ_SECONDS" -gt "$MAX_SECONDS" ]; then
                        warn "VM '${VM_NAME}': port ${REQ_PORT} allows at most ${PORT_MAX_DURATION} per request; requesting ${PORT_MAX_DURATION} instead of ${DURATION}."
                        EFFECTIVE_DURATION="$PORT_MAX_DURATION"
                    fi
                fi

                jq -nc \
                    --arg id "$VM_ID" \
                    --arg name "$VM_NAME" \
                    --arg location "$LOCATION" \
                    --arg subscriptionId "$SUB_ID" \
                    --arg subscriptionDisplay "$SUB_RAW" \
                    --arg resourceGroup "$RG" \
                    --arg duration "$EFFECTIVE_DURATION" \
                    --argjson port "$REQ_PORT" \
                    --argjson prefixes "$PREFIXES" \
                    --argjson usedFileRanges "$([ "$USE_FILE_RANGES" = "true" ] && echo true || echo false)" \
                    '
                    {
                      vmName: $name,
                      id: $id,
                      location: $location,
                      subscriptionId: $subscriptionId,
                      subscriptionDisplay: $subscriptionDisplay,
                      resourceGroup: $resourceGroup,
                      usedFileRanges: $usedFileRanges,
                      ports: [
                        {
                          number: $port,
                          allowedSourceAddressPrefixes: $prefixes,
                          duration: $duration
                        }
                      ]
                    }
                    ' >> "$PLAN_FILE"
            done < "$ROW_PORTS_FILE"
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
        P_DURATION=$(printf '%s' "$PLAN_LINE" | jq -r '.ports[0].duration')
        P_SOURCE_LABEL="JIT policy"
        if [ "$(printf '%s' "$PLAN_LINE" | jq -r '.usedFileRanges')" = "true" ]; then
            P_SOURCE_LABEL="input file ip-ranges"
        fi
        info "  ${P_NAME} (${P_SUB}/${P_RG}): port ${P_PORT} -> source ${P_PREFIXES} (${P_SOURCE_LABEL}), duration ${P_DURATION}"
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

        # Merge by VM id: if the same VM appears on more than one input-file row
        # (e.g. one row per port), union their ports instead of sending Azure two
        # separate entries for the same VM id, which it rejects outright. Matched
        # case-insensitively, since Azure resource IDs are case-insensitive but the
        # policy may already store a different letter-casing than `az vm show`
        # returns for the same VM.
        NEW_VMS_JSON=$(
            jq -sc '
                group_by(.id | ascii_downcase)
                | map({
                    id: (.[-1].id),
                    ports: (map(.ports) | flatten | group_by(.number) | map(.[-1]))
                  })
            ' "$GROUP_PLAN"
        )

        MERGED_BODY=$(
            jq -n \
                --arg location "$LOCATION" \
                --argjson newVms "$NEW_VMS_JSON" \
                --slurpfile existing "$POLICY_FILE" \
                '
                (($existing[0].properties.virtualMachines) // []) as $existingVms
                | ($existingVms + $newVms) as $combined
                | {
                    kind: "Basic",
                    location: $location,
                    properties: {
                      virtualMachines: (
                          $combined
                          | group_by(.id | ascii_downcase)
                          | map({
                              id: (.[-1].id),
                              ports: ((map(.ports) | flatten) | group_by(.number) | map(.[-1]))
                            })
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
