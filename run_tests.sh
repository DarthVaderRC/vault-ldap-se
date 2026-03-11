#!/usr/bin/env bash
###############################################################################
# Run the full test suite for the Vault LDAP Secrets Engine demo
#
# Prerequisites:
#   - OpenLDAP container running (run setup/00_openldap_setup.sh)
#   - LDAP engine configured (run setup/02_ldap_engine_config.sh)
#   - Python deps installed: pip3 install -r requirements.txt
#
# Environment variables:
#   VAULT_ADDR        (default: http://127.0.0.1:8200)
#   VAULT_ROOT_TOKEN  (required)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:?VAULT_ROOT_TOKEN must be set}"

echo "=== Vault LDAP Secrets Engine Test Suite ==="
echo "Vault: ${VAULT_ADDR}"
echo ""

# Reset state for clean test run
echo "Resetting LDAP admin password..."
docker exec -i vault-ldap-openldap ldapmodify -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: cn=admin,dc=learn,dc=example
changetype: modify
replace: userPassword
userPassword: 2LearnVault
EOF

OPENLDAP_IP=$(docker inspect vault-ldap-openldap --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
vault write ldap/config \
    binddn="cn=admin,dc=learn,dc=example" \
    bindpass="2LearnVault" \
    url="ldap://${OPENLDAP_IP}" \
    schema="openldap" \
    userdn="ou=users,dc=learn,dc=example" \
    userattr="cn" >/dev/null 2>&1

# Clean any leftover roles
for role in alice bob alice-policy org/dev org/platform/sre; do
    vault delete "ldap/static-role/${role}" 2>/dev/null || true
done
vault write ldap/config password_policy="" 2>/dev/null || true

echo ""
echo "Running pytest..."
python3 -m pytest tests/ -v "$@"
