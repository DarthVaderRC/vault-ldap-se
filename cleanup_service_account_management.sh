#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set}"

CONTAINER_NAME="${SAM_OPENLDAP_CONTAINER:-vault-ldap-openldap}"
CENTRAL_NAMESPACE="${SAM_CENTRAL_NAMESPACE:-ns-central}"
TENANT_NAMESPACE="${SAM_TENANT_NAMESPACE:-ns-engineering-1}"
SHARED_MOUNT="${SAM_SHARED_MOUNT:-ldap-engineering}"
LDAP_BRANCH_DN="${SAM_LDAP_BRANCH_DN:-dc=engineering,dc=hashicups,dc=local}"
LDAP_SERVICE_ACCOUNTS_DN="${SAM_LDAP_SERVICE_ACCOUNTS_DN:-ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_VAULT_OU_DN="${SAM_LDAP_VAULT_OU_DN:-ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_SERVICE_ACCOUNT_DN="${SAM_LDAP_SERVICE_ACCOUNT_DN:-cn=svc-app1,ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_DELEGATED_ADMIN_OU_DN="${SAM_LDAP_DELEGATED_ADMIN_OU_DN:-ou=delegated-admin,dc=engineering,dc=hashicups,dc=local}"
LDAP_BIND_DN="${SAM_LDAP_BIND_DN:-cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local}"
RESTORE_GROUP_POLICY_MODE="${SAM_RESTORE_GROUP_POLICY_MODE:-}"

echo "=== Cleaning up service-account-management demo resources ==="

delete_if_present() {
    local entry_dn="$1"

    docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF || true
dn: ${entry_dn}
changetype: delete
EOF
}

if VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault secrets disable "${SHARED_MOUNT}/" >/dev/null 2>&1; then
    echo "Disabled ${SHARED_MOUNT}/ in ${CENTRAL_NAMESPACE}."
fi

if vault namespace delete "${CENTRAL_NAMESPACE}" >/dev/null 2>&1; then
    echo "Deleted namespace ${CENTRAL_NAMESPACE}."
fi

if vault namespace delete "${TENANT_NAMESPACE}" >/dev/null 2>&1; then
    echo "Deleted namespace ${TENANT_NAMESPACE}."
fi

if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    delete_if_present "${LDAP_SERVICE_ACCOUNT_DN}"
    delete_if_present "${LDAP_VAULT_OU_DN}"
    delete_if_present "${LDAP_BIND_DN}"
    delete_if_present "${LDAP_DELEGATED_ADMIN_OU_DN}"
    delete_if_present "${LDAP_SERVICE_ACCOUNTS_DN}"
    delete_if_present "${LDAP_BRANCH_DN}"
    echo "Removed known LDAP demo entries under ${LDAP_BRANCH_DN}."
fi

if [ -n "${RESTORE_GROUP_POLICY_MODE}" ]; then
    CURRENT_MODE="$(
        vault read -format=json sys/config/group-policy-application 2>/dev/null | \
            jq -r '.data.group_policy_application_mode // empty'
    )"
    if [ -n "${CURRENT_MODE}" ] && [ "${CURRENT_MODE}" != "${RESTORE_GROUP_POLICY_MODE}" ]; then
        vault write sys/config/group-policy-application \
            group_policy_application_mode="${RESTORE_GROUP_POLICY_MODE}" >/dev/null
        echo "Restored group policy application mode to ${RESTORE_GROUP_POLICY_MODE}."
    fi
fi

echo "Cleanup complete."
echo "Note: delegated-bind ACLs are additive and may remain in OpenLDAP config, and OpenLDAP may retain the empty branch shell even after child entries are removed."
