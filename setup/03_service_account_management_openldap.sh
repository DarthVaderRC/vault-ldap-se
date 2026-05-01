#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="${SAM_OPENLDAP_CONTAINER:-vault-ldap-openldap}"
LDAP_BRANCH_DN="${SAM_LDAP_BRANCH_DN:-dc=engineering,dc=hashicups,dc=local}"
LDAP_USERDN="${SAM_LDAP_USERDN:-ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_BIND_DN="${SAM_LDAP_BIND_DN:-cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local}"
LDAP_BIND_PASS="${SAM_LDAP_BIND_PASS:-VaultBindEngineering!1}"
LDAP_VAULT_OU_DN="${SAM_LDAP_VAULT_OU_DN:-ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_SERVICE_ACCOUNT_DN="${SAM_LDAP_SERVICE_ACCOUNT_DN:-cn=svc-app1,ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_DELEGATED_ADMIN_OU_DN="${SAM_LDAP_DELEGATED_ADMIN_OU_DN:-ou=delegated-admin,dc=engineering,dc=hashicups,dc=local}"
LDIF_PATH="${SCRIPT_DIR}/service_account_management/engineering_branch.ldif"
LDIF_DEST="/tmp/service-account-management-engineering.ldif"

echo "=== Preparing OpenLDAP for service-account-management demo ==="

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "OpenLDAP container ${CONTAINER_NAME} not found. Run setup/00_openldap_setup.sh first." >&2
    exit 1
fi

delete_if_present() {
    local entry_dn="$1"

    docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF || true
dn: ${entry_dn}
changetype: delete
EOF
}

echo "Resetting known demo entries under ${LDAP_BRANCH_DN}..."
delete_if_present "${LDAP_SERVICE_ACCOUNT_DN}"
delete_if_present "${LDAP_VAULT_OU_DN}"
delete_if_present "${LDAP_BIND_DN}"
delete_if_present "${LDAP_DELEGATED_ADMIN_OU_DN}"

docker cp "${LDIF_PATH}" "${CONTAINER_NAME}:${LDIF_DEST}"
set +e
LDAPADD_OUTPUT="$(
    docker exec "${CONTAINER_NAME}" ldapadd -c -Y EXTERNAL -H ldapi:/// -f "${LDIF_DEST}" 2>&1
)"
LDAPADD_STATUS=$?
set -e
if [ "${LDAPADD_STATUS}" -ne 0 ] && [ "${LDAPADD_STATUS}" -ne 68 ]; then
    echo "${LDAPADD_OUTPUT}" >&2
    exit "${LDAPADD_STATUS}"
fi

ACCESS_DUMP="$(
    docker exec "${CONTAINER_NAME}" ldapsearch -LLL -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// \
        -b "olcDatabase={1}mdb,cn=config" olcAccess 2>/dev/null || true
)"

if ! grep -Fq "${LDAP_BIND_DN}" <<<"${ACCESS_DUMP}"; then
    echo "Adding scoped ACLs for ${LDAP_BIND_DN}..."
    set +e
    ACL_OUTPUT="$(
        docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// 2>&1 <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}to dn.subtree="${LDAP_USERDN}" attrs=userPassword by dn.exact="${LDAP_BIND_DN}" write by self write by anonymous auth by * none
-
add: olcAccess
olcAccess: {1}to dn.subtree="${LDAP_USERDN}" by dn.exact="${LDAP_BIND_DN}" read by * none
EOF
    )"
    ACL_STATUS=$?
    set -e
    if [ "${ACL_STATUS}" -ne 0 ] && [ "${ACL_STATUS}" -ne 20 ]; then
        echo "${ACL_OUTPUT}" >&2
        exit "${ACL_STATUS}"
    fi
else
    echo "Scoped ACLs for ${LDAP_BIND_DN} already present."
fi

echo "Verifying delegated bind account can authenticate..."
docker exec "${CONTAINER_NAME}" ldapwhoami -x -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASS}" >/dev/null

echo "Verifying delegated bind account can read the Vault-managed OU..."
docker exec "${CONTAINER_NAME}" ldapsearch -x -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASS}" \
    -b "${LDAP_USERDN}" "(cn=svc-app1)" cn >/dev/null

echo "OpenLDAP branch ready:"
echo "  Branch DN: ${LDAP_BRANCH_DN}"
echo "  Bind DN:   ${LDAP_BIND_DN}"
echo "  User DN:   ${LDAP_USERDN}"
