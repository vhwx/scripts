#!/usr/bin/env bash
#
# Script:       az-pim-activate.sh
# Description:  Interactive Azure PIM (Privileged Identity Management) activation for
#               Azure resource roles. Lists the signed-in user's eligible RBAC
#               assignments (direct and group-derived) across accessible subscriptions
#               in the current tenant, lets you pick one via fzf (if installed) or a
#               numbered menu, then submits a self-activation request via the ARM REST
#               API.
# Usage:        ./az-pim-activate.sh
#               ./az-pim-activate.sh --duration PT4H
#               ./az-pim-activate.sh --justification "Planned maintenance"
#               ./az-pim-activate.sh --subscription <subscription-id>
#               ./az-pim-activate.sh --dry-run
#               Run with -h/--help for the full option list.
# Requirements: Azure CLI (logged in via `az login`), jq. fzf is optional but gives a
#               searchable menu; falls back to a numbered menu otherwise. Requires
#               subscription- or resource-group-scoped PIM eligibility on the signed-in
#               user (or via group membership) — Entra ID PIM roles are out of scope.
#               Tested on macOS and Linux with Bash 3.2+.
# Author:       Vegard Hoff Walmsness
# Date:         2026-09-15
#
# NOTE: This script intentionally uses `set -u` plus explicit `||` error checks rather
# than `set -e`, because several steps (fzf cancellation, optional az/jq lookups with
# graceful fallbacks) rely on inspecting exit codes without aborting the whole script.

set -u

API_VERSION="2020-10-01"
DURATION="PT1H"
JUSTIFICATION=""
SUBSCRIPTION_FILTER=""
DRY_RUN="false"
KEEP_CONTEXT="false"

PROGRAM_NAME=$(basename "$0")
TMP_DIR=""

usage() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} [options]

Options:
  --subscription ID       Search only this subscription
  --duration ISO8601      Requested activation duration, default: PT1H
  --justification TEXT    Activation justification
  --keep-context          Do not switch az CLI to the selected subscription
  --dry-run               Show the activation request without submitting it
  -h, --help              Show this help

Duration examples:
  PT30M                   30 minutes
  PT1H                    1 hour
  PT4H                    4 hours
  PT8H                    8 hours

Examples:
  ${PROGRAM_NAME}
  ${PROGRAM_NAME} --duration PT4H
  ${PROGRAM_NAME} --justification "Troubleshooting production issue"
  ${PROGRAM_NAME} --subscription 00000000-0000-0000-0000-000000000000
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

make_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    else
        die "Neither uuidgen nor python3 is available to generate a request ID."
    fi
}

iso_utc_now() {
    # This format works with both BSD date on macOS and GNU date on Linux.
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

url_encode_filter() {
    # Produces:
    # assignedTo%28%27<GUID>%27%29
    printf "assignedTo%%28%%27%s%%27%%29" "$1"
}

scope_type() {
    case "$1" in
        /subscriptions/*/resourceGroups/*/providers/*)
            printf '%s' "Resource"
            ;;
        /subscriptions/*/resourceGroups/*)
            printf '%s' "Resource group"
            ;;
        /subscriptions/*)
            printf '%s' "Subscription"
            ;;
        /providers/Microsoft.Management/managementGroups/*)
            printf '%s' "Management group"
            ;;
        *)
            printf '%s' "Other"
            ;;
    esac
}

scope_short_name() {
    scope="$1"

    case "$scope" in
        /subscriptions/*/resourceGroups/*/providers/*)
            printf '%s' "$scope" | awk -F/ '{
                printf "%s/%s/%s", $5, $(NF-1), $NF
            }'
            ;;
        /subscriptions/*/resourceGroups/*)
            printf '%s' "$scope" | awk -F/ '{print $5}'
            ;;
        /subscriptions/*)
            printf '%s' "subscription root"
            ;;
        /providers/Microsoft.Management/managementGroups/*)
            printf '%s' "$scope" | awk -F/ '{print $5}'
            ;;
        *)
            printf '%s' "$scope"
            ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --subscription)
            [ "$#" -ge 2 ] || die "--subscription requires a value"
            SUBSCRIPTION_FILTER="$2"
            shift 2
            ;;
        --duration)
            [ "$#" -ge 2 ] || die "--duration requires a value"
            DURATION="$2"
            shift 2
            ;;
        --justification)
            [ "$#" -ge 2 ] || die "--justification requires a value"
            JUSTIFICATION="$2"
            shift 2
            ;;
        --keep-context)
            KEEP_CONTEXT="true"
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

case "$DURATION" in
    P*)
        ;;
    *)
        die "Duration must use ISO 8601 format, for example PT1H or PT30M."
        ;;
esac

require_command az
require_command jq

az account show >/dev/null 2>&1 ||
    die "Azure CLI is not logged in. Run: az login"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/az-pim.XXXXXX") ||
    die "Could not create temporary directory"

RAW_ASSIGNMENTS="${TMP_DIR}/raw-assignments.jsonl"
ASSIGNMENTS="${TMP_DIR}/assignments.json"
MENU="${TMP_DIR}/menu.tsv"
SUBSCRIPTIONS="${TMP_DIR}/subscriptions.tsv"

: > "$RAW_ASSIGNMENTS"
: > "$MENU"

PRINCIPAL_ID=$(
    az ad signed-in-user show \
        --query id \
        --output tsv 2>/dev/null
) || die "Could not determine the signed-in user's object ID."

[ -n "$PRINCIPAL_ID" ] ||
    die "Azure CLI returned an empty principal ID."

CURRENT_TENANT=$(
    az account show --query tenantId --output tsv 2>/dev/null
)

SIGNED_IN_USER=$(
    az ad signed-in-user show \
        --query userPrincipalName \
        --output tsv 2>/dev/null || true
)

if [ -n "$SIGNED_IN_USER" ]; then
    info "Signed in as: ${SIGNED_IN_USER}"
fi

info "Principal ID: ${PRINCIPAL_ID}"
info "Tenant ID:    ${CURRENT_TENANT}"
info ""

if [ -n "$SUBSCRIPTION_FILTER" ]; then
    az account show \
        --subscription "$SUBSCRIPTION_FILTER" \
        --query '[id,name,tenantId]' \
        --output tsv > "$SUBSCRIPTIONS" 2>/dev/null ||
        die "Subscription is unavailable: ${SUBSCRIPTION_FILTER}"
else
    az account list \
        --all \
        --query "[?state=='Enabled' && tenantId=='${CURRENT_TENANT}'].[id,name,tenantId]" \
        --output tsv > "$SUBSCRIPTIONS" ||
        die "Could not retrieve Azure subscriptions."
fi

[ -s "$SUBSCRIPTIONS" ] ||
    die "No enabled subscriptions were found in the current tenant."

SUBSCRIPTION_COUNT=$(wc -l < "$SUBSCRIPTIONS" | tr -d ' ')
info "Searching ${SUBSCRIPTION_COUNT} accessible subscription(s)..."

ENCODED_FILTER=$(url_encode_filter "$PRINCIPAL_ID")

while IFS="$(printf '\t')" read -r SUBSCRIPTION_ID SUBSCRIPTION_NAME _; do
    [ -n "$SUBSCRIPTION_ID" ] || continue

    info "  ${SUBSCRIPTION_NAME}"

    URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=${API_VERSION}&%24filter=${ENCODED_FILTER}"

    while [ -n "$URL" ]; do
        RESPONSE_FILE="${TMP_DIR}/response-${SUBSCRIPTION_ID}.json"

        if ! az rest \
            --method GET \
            --uri "$URL" \
            --output json > "$RESPONSE_FILE" 2>"${TMP_DIR}/error.log"; then

            ERROR_TEXT=$(cat "${TMP_DIR}/error.log")
            warn "Could not query ${SUBSCRIPTION_NAME}: ${ERROR_TEXT}"
            break
        fi

        jq -c \
            --arg subscriptionId "$SUBSCRIPTION_ID" \
            --arg subscriptionName "$SUBSCRIPTION_NAME" \
            '.value[] |
             {
               id: .id,
               name: .name,
               subscriptionId: $subscriptionId,
               subscriptionName: $subscriptionName,
               scope: (.properties.scope // ""),
               principalId: (.properties.principalId // ""),
               roleDefinitionId: (.properties.roleDefinitionId // ""),
               eligibilityScheduleId:
                   (.properties.roleEligibilityScheduleId // ""),
               memberType: (.properties.memberType // ""),
               status: (.properties.status // ""),
               condition: (.properties.condition // ""),
               conditionVersion: (.properties.conditionVersion // ""),
               roleDisplayName:
                   (.properties.expandedProperties.roleDefinition.displayName // ""),
               scopeDisplayName:
                   (.properties.expandedProperties.scope.displayName // "")
             }' "$RESPONSE_FILE" >> "$RAW_ASSIGNMENTS"

        URL=$(jq -r '.nextLink // empty' "$RESPONSE_FILE")
    done
done < "$SUBSCRIPTIONS"

if [ ! -s "$RAW_ASSIGNMENTS" ]; then
    die "No eligible Azure resource-role assignments were found."
fi

jq -s '
    map(
        select(.scope != "") |
        select(.roleDefinitionId != "") |
        select(.eligibilityScheduleId != "")
    )
    | unique_by(
        .scope + "|" +
        .roleDefinitionId + "|" +
        .eligibilityScheduleId
    )
' "$RAW_ASSIGNMENTS" > "$ASSIGNMENTS"

ASSIGNMENT_COUNT=$(jq 'length' "$ASSIGNMENTS")

[ "$ASSIGNMENT_COUNT" -gt 0 ] ||
    die "No activatable assignments remained after validation."

# Resolve missing role display names individually. In many responses,
# expandedProperties already contains this information.
INDEX=0
while [ "$INDEX" -lt "$ASSIGNMENT_COUNT" ]; do
    ROLE_NAME=$(jq -r ".[$INDEX].roleDisplayName // empty" "$ASSIGNMENTS")
    ROLE_DEFINITION_ID=$(jq -r ".[$INDEX].roleDefinitionId" "$ASSIGNMENTS")
    SCOPE=$(jq -r ".[$INDEX].scope" "$ASSIGNMENTS")

    if [ -z "$ROLE_NAME" ]; then
        ROLE_GUID=$(printf '%s' "$ROLE_DEFINITION_ID" | awk -F/ '{print $NF}')

        ROLE_NAME=$(
            az role definition list \
                --name "$ROLE_GUID" \
                --scope "$SCOPE" \
                --query '[0].roleName' \
                --output tsv 2>/dev/null || true
        )

        if [ -z "$ROLE_NAME" ]; then
            ROLE_NAME="$ROLE_GUID"
        fi

        UPDATED="${TMP_DIR}/assignments-updated.json"

        jq \
            --argjson index "$INDEX" \
            --arg roleName "$ROLE_NAME" \
            '.[$index].roleDisplayName = $roleName' \
            "$ASSIGNMENTS" > "$UPDATED"

        mv "$UPDATED" "$ASSIGNMENTS"
    fi

    INDEX=$((INDEX + 1))
done

INDEX=0
while [ "$INDEX" -lt "$ASSIGNMENT_COUNT" ]; do
    ROLE_NAME=$(jq -r ".[$INDEX].roleDisplayName" "$ASSIGNMENTS")
    SCOPE=$(jq -r ".[$INDEX].scope" "$ASSIGNMENTS")
    SCOPE_DISPLAY=$(jq -r ".[$INDEX].scopeDisplayName // empty" "$ASSIGNMENTS")
    SUBSCRIPTION_NAME=$(jq -r ".[$INDEX].subscriptionName" "$ASSIGNMENTS")
    MEMBER_TYPE=$(jq -r ".[$INDEX].memberType // empty" "$ASSIGNMENTS")

    TYPE=$(scope_type "$SCOPE")

    if [ -z "$SCOPE_DISPLAY" ]; then
        SCOPE_DISPLAY=$(scope_short_name "$SCOPE")
    fi

    # Replace tabs and newlines so each assignment remains one menu line.
    ROLE_NAME=$(printf '%s' "$ROLE_NAME" | tr '\t\r\n' '   ')
    SCOPE_DISPLAY=$(printf '%s' "$SCOPE_DISPLAY" | tr '\t\r\n' '   ')
    SUBSCRIPTION_NAME=$(printf '%s' "$SUBSCRIPTION_NAME" | tr '\t\r\n' '   ')
    MEMBER_TYPE=$(printf '%s' "$MEMBER_TYPE" | tr '\t\r\n' '   ')

    printf '%s\t%-24s\t%-15s\t%-32s\t%-28s\t%s\n' \
        "$INDEX" \
        "$ROLE_NAME" \
        "$TYPE" \
        "$SCOPE_DISPLAY" \
        "$SUBSCRIPTION_NAME" \
        "$MEMBER_TYPE" >> "$MENU"

    INDEX=$((INDEX + 1))
done

info ""
info "Found ${ASSIGNMENT_COUNT} eligible assignment(s)."

SELECTED_INDEX=""

if command -v fzf >/dev/null 2>&1; then
    SELECTED_LINE=$(
        fzf \
            --height=80% \
            --layout=reverse \
            --border \
            --delimiter="$(printf '\t')" \
            --with-nth=2.. \
            --header="ROLE | SCOPE TYPE | SCOPE | SUBSCRIPTION | MEMBERSHIP" \
            --prompt="Activate PIM role > " \
            < "$MENU"
    ) || exit 0

    SELECTED_INDEX=$(printf '%s' "$SELECTED_LINE" | cut -f1)
else
    info ""
    info "Tip: install fzf for a searchable interactive menu."
    info ""

    awk -F '\t' '{
        printf "%3d) %s | %s | %s | %s | %s\n",
            NR, $2, $3, $4, $5, $6
    }' "$MENU" >&2

    info ""
    printf 'Select assignment [1-%s], or q to quit: ' \
        "$ASSIGNMENT_COUNT" >&2

    IFS= read -r CHOICE

    case "$CHOICE" in
        q|Q)
            exit 0
            ;;
        ''|*[!0-9]*)
            die "Invalid selection."
            ;;
    esac

    if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$ASSIGNMENT_COUNT" ]; then
        die "Selection is outside the valid range."
    fi

    SELECTED_INDEX=$((CHOICE - 1))
fi

SELECTED=$(
    jq -c --argjson index "$SELECTED_INDEX" \
        '.[$index]' "$ASSIGNMENTS"
)

SCOPE=$(printf '%s' "$SELECTED" | jq -r '.scope')
ROLE_NAME=$(printf '%s' "$SELECTED" | jq -r '.roleDisplayName')
ROLE_DEFINITION_ID=$(printf '%s' "$SELECTED" | jq -r '.roleDefinitionId')
ELIGIBILITY_SCHEDULE_ID=$(
    printf '%s' "$SELECTED" |
        jq -r '.eligibilityScheduleId'
)
SELECTED_SUBSCRIPTION_ID=$(
    printf '%s' "$SELECTED" |
        jq -r '.subscriptionId'
)
SELECTED_SUBSCRIPTION_NAME=$(
    printf '%s' "$SELECTED" |
        jq -r '.subscriptionName'
)
CONDITION=$(printf '%s' "$SELECTED" | jq -r '.condition // empty')
CONDITION_VERSION=$(
    printf '%s' "$SELECTED" |
        jq -r '.conditionVersion // empty'
)

info ""
info "Selected assignment"
info "  Role:         ${ROLE_NAME}"
info "  Scope:        ${SCOPE}"
info "  Subscription: ${SELECTED_SUBSCRIPTION_NAME}"
info "  Duration:     ${DURATION}"

if [ -z "$JUSTIFICATION" ]; then
    printf 'Justification: ' >&2
    IFS= read -r JUSTIFICATION
fi

[ -n "$JUSTIFICATION" ] ||
    die "A justification is required."

REQUEST_ID=$(make_uuid)
START_TIME=$(iso_utc_now)

BODY=$(
    jq -n \
        --arg principalId "$PRINCIPAL_ID" \
        --arg roleDefinitionId "$ROLE_DEFINITION_ID" \
        --arg eligibilityScheduleId "$ELIGIBILITY_SCHEDULE_ID" \
        --arg startDateTime "$START_TIME" \
        --arg duration "$DURATION" \
        --arg justification "$JUSTIFICATION" \
        --arg condition "$CONDITION" \
        --arg conditionVersion "$CONDITION_VERSION" \
        '
        {
          properties: {
            principalId: $principalId,
            requestType: "SelfActivate",
            roleDefinitionId: $roleDefinitionId,
            linkedRoleEligibilityScheduleId:
                $eligibilityScheduleId,
            justification: $justification,
            scheduleInfo: {
              startDateTime: $startDateTime,
              expiration: {
                type: "AfterDuration",
                duration: $duration
              }
            }
          }
        }
        | if $condition != "" then
            .properties.condition = $condition
          else
            .
          end
        | if $conditionVersion != "" then
            .properties.conditionVersion = $conditionVersion
          else
            .
          end
        '
)

ACTIVATION_URI="https://management.azure.com${SCOPE}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/${REQUEST_ID}?api-version=${API_VERSION}"

if [ "$DRY_RUN" = "true" ]; then
    info ""
    info "Dry run. No activation request was submitted."
    info ""
    printf 'PUT %s\n\n' "$ACTIVATION_URI"
    printf '%s\n' "$BODY" | jq .
    exit 0
fi

info ""
info "Submitting PIM activation request..."

RESPONSE=$(
    az rest \
        --method PUT \
        --uri "$ACTIVATION_URI" \
        --headers 'Content-Type=application/json' \
        --body "$BODY" \
        --output json
) || die "PIM activation request failed."

STATUS=$(printf '%s' "$RESPONSE" | jq -r '.properties.status // "Unknown"')
REQUEST_NAME=$(printf '%s' "$RESPONSE" | jq -r '.name // empty')

info ""
info "Activation request submitted."
info "  Request ID: ${REQUEST_NAME:-$REQUEST_ID}"
info "  Status:     ${STATUS}"
info "  Role:       ${ROLE_NAME}"
info "  Scope:      ${SCOPE}"

case "$STATUS" in
    Granted|Provisioned|Succeeded)
        info "  Result:     Access was activated."
        ;;
    PendingApproval|PendingAdminDecision|PendingScheduleCreation)
        info "  Result:     The request is pending."
        ;;
    *)
        info "  Result:     Review the returned status above."
        ;;
esac

if [ "$KEEP_CONTEXT" != "true" ]; then
    if az account set \
        --subscription "$SELECTED_SUBSCRIPTION_ID" 2>/dev/null; then
        info ""
        info "Azure CLI context changed to:"
        info "  ${SELECTED_SUBSCRIPTION_NAME}"
    else
        warn "Activation was submitted, but az account set failed."
    fi
fi
