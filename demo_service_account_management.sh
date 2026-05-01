#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
    cat <<'EOF'
Usage: ./demo_service_account_management.sh [options]

Focused cross-namespace service-account-management demo for Vault Enterprise.

Options:
  --auto         Run non-interactively with no pause prompts
  --skip-setup   Reuse existing service-account-management setup
  --no-cleanup   Keep namespaces, mount, and LDAP branch after the demo
  -h, --help     Show this help text and exit

Environment:
  VAULT_ADDR     Vault address (default: http://127.0.0.1:8200)
  VAULT_TOKEN    Required token with namespace and identity admin privileges
EOF
}

AUTO_MODE=false
SKIP_SETUP=false
NO_CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE=true ;;
        --skip-setup) SKIP_SETUP=true ;;
        --no-cleanup) NO_CLEANUP=true ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set}"
unset VAULT_NAMESPACE

CENTRAL_NAMESPACE="${SAM_CENTRAL_NAMESPACE:-ns-central}"
TENANT_NAMESPACE="${SAM_TENANT_NAMESPACE:-ns-engineering-1}"
SHARED_MOUNT="${SAM_SHARED_MOUNT:-ldap-engineering}"
DEMO_USER="${SAM_DEMO_USER:-demo-user}"
DEMO_PASSWORD="${SAM_DEMO_PASSWORD:-CrossNamespaceDemo!1}"
ROLE_PATH="${SAM_ROLE_PATH:-ns-engineering-1/team1/app1/static/svc-app1}"
LDAP_STATIC_DN="${SAM_LDAP_STATIC_DN:-cn=svc-app1,ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
OPENLDAP_CONTAINER="${SAM_OPENLDAP_CONTAINER:-vault-ldap-openldap}"

section() {
    printf '\n== %s ==\n\n' "$1"
}

subsection() {
    printf '\n-- %s --\n' "$1"
}

info() {
    printf '  %s\n' "$1"
}

pause() {
    if [ "${AUTO_MODE}" = false ]; then
        printf '\nPress Enter to continue...'
        read -r
        printf '\n'
    fi
}

run_cmd() {
    printf '  $ %s\n' "$*"
    "$@"
    printf '\n'
}

if GROUP_POLICY_CONFIG_JSON="$(vault read -format=json sys/config/group-policy-application 2>/dev/null)"; then
    ORIGINAL_GROUP_POLICY_MODE="$(
        printf '%s\n' "${GROUP_POLICY_CONFIG_JSON}" | \
            jq -r '.data.group_policy_application_mode // "within_namespace_hierarchy"'
    )"
else
    ORIGINAL_GROUP_POLICY_MODE="within_namespace_hierarchy"
fi
GROUP_POLICY_MODE_CHANGED=false

clear || true
section "Service Account Management Design Demo"
info "Vault address: ${VAULT_ADDR}"
info "Story: one tenant namespace consumes a static role from a shared mount in ${CENTRAL_NAMESPACE}"
info "Mode: $( [ "${AUTO_MODE}" = true ] && echo auto || echo interactive )"
pause

if [ "${SKIP_SETUP}" = false ]; then
    section "1. Bootstrap isolated demo resources"
    info "Cleaning up any previous run with the same namespace and mount names."
    bash "${SCRIPT_DIR}/cleanup_service_account_management.sh" >/dev/null 2>&1 || true

    subsection "Enable cross-namespace group policy application"
    run_cmd "vault write sys/config/group-policy-application group_policy_application_mode=any"
    if [ "${ORIGINAL_GROUP_POLICY_MODE}" != "any" ]; then
        GROUP_POLICY_MODE_CHANGED=true
    fi

    subsection "Prepare OpenLDAP branch for delegated bind + Vault-managed OU"
    run_cmd "bash \"${SCRIPT_DIR}/setup/03_service_account_management_openldap.sh\""

    subsection "Create namespaces, identity mapping, shared mount, and static role"
    run_cmd "bash \"${SCRIPT_DIR}/setup/04_service_account_management_vault.sh\""
    pause
else
    section "1. Reusing existing setup"
    info "Skipping setup. The demo assumes the namespaces, mount, and LDAP branch already exist."
    pause
fi

section "2. Show the high-level design boundary"
subsection "Peer namespaces with a shared administrative namespace"
run_cmd "vault namespace list"
info "The demo keeps one consumer namespace (${TENANT_NAMESPACE}) separate from the shared administrative namespace (${CENTRAL_NAMESPACE})."
pause

subsection "The shared mount lives in ${CENTRAL_NAMESPACE}"
run_cmd "VAULT_NAMESPACE=\"${CENTRAL_NAMESPACE}\" vault secrets list"
run_cmd "VAULT_NAMESPACE=\"${CENTRAL_NAMESPACE}\" vault list ${SHARED_MOUNT}/static-role"
run_cmd "VAULT_NAMESPACE=\"${CENTRAL_NAMESPACE}\" vault read ${SHARED_MOUNT}/static-role/${ROLE_PATH}"
pause

ENTITY_NAME="${SAM_ENTITY_NAME:-ns-engineering-1-demo-user}"
GROUP_NAME="${SAM_GROUP_NAME:-engineering-static-consumers}"

section "3. Show the identity bridge"
subsection "Tenant auth method and entity alias"
run_cmd "VAULT_NAMESPACE=\"${TENANT_NAMESPACE}\" vault auth list"
run_cmd "VAULT_NAMESPACE=\"${TENANT_NAMESPACE}\" vault read identity/entity/name/${ENTITY_NAME}"

subsection "Shared group in ${CENTRAL_NAMESPACE}"
run_cmd "VAULT_NAMESPACE=\"${CENTRAL_NAMESPACE}\" vault read identity/group/name/${GROUP_NAME}"
info "The group policy lives in ${CENTRAL_NAMESPACE}, but its member entity lives in ${TENANT_NAMESPACE}."
pause

section "4. Read a shared static credential with a tenant token"
subsection "Authenticate in ${TENANT_NAMESPACE}"
TENANT_TOKEN="$(
    VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault write -field=token \
        "auth/userpass/login/${DEMO_USER}" password="${DEMO_PASSWORD}"
)"
info "Authenticated ${DEMO_USER} in ${TENANT_NAMESPACE}."

subsection "Use the tenant token in ${CENTRAL_NAMESPACE}"
run_cmd "VAULT_NAMESPACE=\"${CENTRAL_NAMESPACE}\" VAULT_TOKEN=\"${TENANT_TOKEN}\" vault read ${SHARED_MOUNT}/static-cred/${ROLE_PATH}"
STATIC_PASSWORD="$(
    VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" VAULT_TOKEN="${TENANT_TOKEN}" \
        vault read -field=password "${SHARED_MOUNT}/static-cred/${ROLE_PATH}"
)"

subsection "Verify the credential works against LDAP"
run_cmd "docker exec \"${OPENLDAP_CONTAINER}\" ldapwhoami -x -D \"${LDAP_STATIC_DN}\" -w \"${STATIC_PASSWORD}\""
info "This proves the tenant token can consume a static role from a shared namespace without owning the LDAP mount locally."
pause

section "5. Summary"
info "Shared administrative namespace: ${CENTRAL_NAMESPACE}"
info "Tenant namespace: ${TENANT_NAMESPACE}"
info "Shared LDAP mount: ${SHARED_MOUNT}/"
info "Hierarchical role: ${ROLE_PATH}"
info "Key design point: cross-namespace access is the main story; full multi-team scale-out is intentionally out of scope."

if [ "${NO_CLEANUP}" = false ]; then
    section "Cleanup"
    if [ "${GROUP_POLICY_MODE_CHANGED}" = true ]; then
        SAM_RESTORE_GROUP_POLICY_MODE="${ORIGINAL_GROUP_POLICY_MODE}" \
            bash "${SCRIPT_DIR}/cleanup_service_account_management.sh"
    else
        bash "${SCRIPT_DIR}/cleanup_service_account_management.sh"
    fi
else
    section "Cleanup skipped"
    info "Resources are still present."
    info "To remove them manually, run: ./cleanup_service_account_management.sh"
fi

printf '\nDemo complete.\n'
