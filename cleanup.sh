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
PHPLDAPADMIN_CONTAINER_NAME="vault-ldap-phpldapadmin"

done_message() {
    echo -e "${GREEN}done${NC}"
}

status_message() {
    echo -e "${RED}$1${NC}"
}

delete_password_policy() {
    vault delete "sys/policies/password/$1" 2>/dev/null || true
}

remove_container() {
    local label="$1"
    local container_name="$2"

    echo -n "  Removing ${label}... "
    if docker rm -f "${container_name}" >/dev/null 2>&1; then
        done_message
    else
        status_message "not running"
    fi
}

echo -e "${CYAN}=== Vault LDAP Secrets Engine Cleanup ===${NC}"
echo ""

# Force revoke any dangling LDAP leases so mount disable works even if
# OpenLDAP has already been removed or credentials were rotated.
echo -n "  Force revoking LDAP leases... "
vault lease revoke -force -prefix ldap >/dev/null 2>&1 || true
done_message

# Disable LDAP secrets engine
echo -n "  Disabling LDAP secrets engine... "
if vault secrets disable ldap/ 2>/dev/null; then
    done_message
else
    status_message "not mounted"
fi

# Remove Vault policies
echo -n "  Removing ldap-admin policy... "
if vault policy delete ldap-admin 2>/dev/null; then
    done_message
else
    status_message "not found"
fi

# Remove password policies
echo -n "  Removing password policies... "
for policy in ldap-policy ldap-demo-policy ldap-custom-policy; do
    delete_password_policy "${policy}"
done
done_message

remove_container "OpenLDAP container" "${CONTAINER_NAME}"
remove_container "phpLDAPadmin container" "${PHPLDAPADMIN_CONTAINER_NAME}"

echo ""
echo -e "${GREEN}Cleanup complete!${NC}"
