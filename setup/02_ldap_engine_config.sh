#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="vault-ldap-openldap"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

# Get OpenLDAP IP
OPENLDAP_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "OpenLDAP IP: ${OPENLDAP_IP}"

echo "=== Enabling LDAP secrets engine ==="

# Disable if already enabled (ignore errors)
vault secrets disable ldap/ 2>/dev/null || true

vault secrets enable ldap

echo ""
echo "=== Configuring LDAP secrets engine ==="
vault write ldap/config \
    binddn="cn=admin,dc=learn,dc=example" \
    bindpass="2LearnVault" \
    url="ldap://${OPENLDAP_IP}" \
    schema="openldap" \
    userdn="ou=users,dc=learn,dc=example" \
    userattr="cn"

echo ""
echo "=== Creating password policy ==="
vault write sys/policies/password/ldap-policy policy=-<<EOF
length=20
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset = "0123456789"
  min-chars = 1
}
rule "charset" {
  charset = "!@#$%^&*"
  min-chars = 1
}
EOF

echo ""
echo "=== Reading config back ==="
vault read ldap/config

echo ""
echo "=== LDAP secrets engine setup complete ==="
