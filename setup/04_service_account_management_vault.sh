#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set}"
unset VAULT_NAMESPACE

CONTAINER_NAME="${SAM_OPENLDAP_CONTAINER:-vault-ldap-openldap}"
CENTRAL_NAMESPACE="${SAM_CENTRAL_NAMESPACE:-ns-central}"
TENANT_NAMESPACE="${SAM_TENANT_NAMESPACE:-ns-engineering-1}"
SHARED_MOUNT="${SAM_SHARED_MOUNT:-ldap-engineering}"
DEMO_USER="${SAM_DEMO_USER:-demo-user}"
DEMO_PASSWORD="${SAM_DEMO_PASSWORD:-CrossNamespaceDemo!1}"
ENTITY_NAME="${SAM_ENTITY_NAME:-ns-engineering-1-demo-user}"
GROUP_NAME="${SAM_GROUP_NAME:-engineering-static-consumers}"
POLICY_NAME="${SAM_POLICY_NAME:-sam-engineering-static-read}"
ROLE_PATH="${SAM_ROLE_PATH:-ns-engineering-1/team1/app1/static/svc-app1}"
LDAP_BIND_DN="${SAM_LDAP_BIND_DN:-cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local}"
LDAP_BIND_PASS="${SAM_LDAP_BIND_PASS:-VaultBindEngineering!1}"
LDAP_USERDN="${SAM_LDAP_USERDN:-ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"
LDAP_STATIC_USERNAME="${SAM_LDAP_STATIC_USERNAME:-svc-app1}"
LDAP_STATIC_DN="${SAM_LDAP_STATIC_DN:-cn=svc-app1,ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local}"

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "OpenLDAP container ${CONTAINER_NAME} not found. Run setup/00_openldap_setup.sh first." >&2
    exit 1
fi

OPENLDAP_IP="$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
if [ -z "${OPENLDAP_IP}" ]; then
    echo "Could not determine the OpenLDAP IP for ${CONTAINER_NAME}." >&2
    exit 1
fi

echo "=== Preparing Vault Enterprise namespaces for service-account-management demo ==="

if ! vault namespace lookup "${CENTRAL_NAMESPACE}" >/dev/null 2>&1; then
    vault namespace create "${CENTRAL_NAMESPACE}" >/dev/null
fi

if ! vault namespace lookup "${TENANT_NAMESPACE}" >/dev/null 2>&1; then
    vault namespace create "${TENANT_NAMESPACE}" >/dev/null
fi

echo "Creating tenant auth path and entity alias..."
if ! VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault auth list -format=json | jq -e 'has("userpass/")' >/dev/null; then
    VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault auth enable userpass >/dev/null
fi
VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault write "auth/userpass/users/${DEMO_USER}" password="${DEMO_PASSWORD}" >/dev/null
USERPASS_ACCESSOR="$(
    VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault auth list -format=json | jq -r '.["userpass/"].accessor'
)"
ENTITY_ID="$(
    VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault write -format=json identity/entity name="${ENTITY_NAME}" | jq -r '.data.id'
)"
VAULT_NAMESPACE="${TENANT_NAMESPACE}" vault write identity/entity-alias \
    name="${DEMO_USER}" \
    canonical_id="${ENTITY_ID}" \
    mount_accessor="${USERPASS_ACCESSOR}" >/dev/null

echo "Creating shared LDAP mount and policy in ${CENTRAL_NAMESPACE}..."
if ! VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault secrets list -format=json | jq -e --arg mount "${SHARED_MOUNT}/" 'has($mount)' >/dev/null; then
    VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault secrets enable -path="${SHARED_MOUNT}" ldap >/dev/null
fi
VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault write "${SHARED_MOUNT}/config" \
    binddn="${LDAP_BIND_DN}" \
    bindpass="${LDAP_BIND_PASS}" \
    url="ldap://${OPENLDAP_IP}" \
    schema="openldap" \
    userdn="${LDAP_USERDN}" \
    userattr="cn" >/dev/null

VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault policy write "${POLICY_NAME}" - >/dev/null <<EOF
path "${SHARED_MOUNT}/static-cred/${ROLE_PATH}" {
  capabilities = ["read"]
}

path "${SHARED_MOUNT}/static-role" {
  capabilities = ["list"]
}

path "${SHARED_MOUNT}/static-role/*" {
  capabilities = ["read", "list"]
}
EOF

VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault write identity/group \
    name="${GROUP_NAME}" \
    policies="${POLICY_NAME}" \
    member_entity_ids="${ENTITY_ID}" >/dev/null

VAULT_NAMESPACE="${CENTRAL_NAMESPACE}" vault write "${SHARED_MOUNT}/static-role/${ROLE_PATH}" \
    dn="${LDAP_STATIC_DN}" \
    username="${LDAP_STATIC_USERNAME}" \
    rotation_period="24h" >/dev/null

echo "Vault setup complete:"
echo "  Central namespace: ${CENTRAL_NAMESPACE}"
echo "  Tenant namespace:  ${TENANT_NAMESPACE}"
echo "  Shared mount:      ${SHARED_MOUNT}/"
echo "  Static role path:  ${SHARED_MOUNT}/static-role/${ROLE_PATH}"
echo "  Demo login:        ${DEMO_USER}"
