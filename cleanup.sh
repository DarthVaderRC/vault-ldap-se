#!/usr/bin/env bash
###############################################################################
# Cleanup script for Vault LDAP Secrets Engine Demo
#
# Removes:
#   - OpenLDAP Docker container
#   - LDAP secrets engine
#   - Vault policies
#   - Password policies
###############################################################################
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set}"
CONTAINER_NAME="vault-ldap-openldap"

echo -e "${CYAN}=== Vault LDAP Secrets Engine Cleanup ===${NC}"
echo ""

# Disable LDAP secrets engine
echo -n "  Disabling LDAP secrets engine... "
if vault secrets disable ldap/ 2>/dev/null; then
    echo -e "${GREEN}done${NC}"
else
    echo -e "${RED}not mounted${NC}"
fi

# Remove Vault policies
echo -n "  Removing ldap-admin policy... "
if vault policy delete ldap-admin 2>/dev/null; then
    echo -e "${GREEN}done${NC}"
else
    echo -e "${RED}not found${NC}"
fi

# Remove password policies
echo -n "  Removing password policies... "
vault delete sys/policies/password/ldap-policy 2>/dev/null || true
vault delete sys/policies/password/ldap-demo-policy 2>/dev/null || true
vault delete sys/policies/password/ldap-custom-policy 2>/dev/null || true
echo -e "${GREEN}done${NC}"

# Remove OpenLDAP container
echo -n "  Removing OpenLDAP container... "
if docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo -e "${GREEN}done${NC}"
else
    echo -e "${RED}not running${NC}"
fi

echo ""
echo -e "${GREEN}Cleanup complete!${NC}"
