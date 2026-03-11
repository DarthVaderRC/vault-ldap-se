#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:?VAULT_ROOT_TOKEN must be set}"

echo "=== Setting up Vault admin policy and token ==="

# Create admin policy
echo "Creating admin policy..."
VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault policy write ldap-admin "${SCRIPT_DIR}/policies/admin-policy.hcl"

# Create admin token
echo "Creating admin token..."
ADMIN_TOKEN=$(VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault token create \
    -policy=ldap-admin \
    -ttl=8h \
    -format=json | jq -r '.auth.client_token')

echo ""
echo "=== Vault policy setup complete ==="
echo "Admin Token: ${ADMIN_TOKEN}"
echo ""
echo "Export this token for subsequent operations:"
echo "  export VAULT_TOKEN=${ADMIN_TOKEN}"
