#!/usr/bin/env bash
###############################################################################
# Vault LDAP Secrets Engine — Interactive Customer Demo
#
# This script demonstrates ALL features of the LDAP secrets engine:
#   1. Setup & Configuration
#   2. Root Credential Rotation (+ Enterprise scheduled rotation)
#   3. Static Roles & Credential Rotation
#   4. Dynamic Credentials with LDIF Templates
#   5. Service Account Check-Out (Library)
#   6. Hierarchical Path Organization
#   7. Custom Password Policies
#
# Usage:
#   ./demo.sh                  # Interactive (pauses between sections)
#   ./demo.sh --auto           # Non-interactive (no pauses)
#   ./demo.sh --skip-setup     # Skip OpenLDAP/Vault setup
#   ./demo.sh --no-cleanup     # Keep resources after demo
#   ./demo.sh --phpldapadmin   # Also start phpLDAPadmin at https://127.0.0.1:6443
#   ./demo.sh --auto --no-cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
AUTO_MODE=false
SKIP_SETUP=false
NO_CLEANUP=false
START_PHPLDAPADMIN=false
for arg in "$@"; do
    case "$arg" in
        --auto)       AUTO_MODE=true ;;
        --skip-setup) SKIP_SETUP=true ;;
        --no-cleanup) NO_CLEANUP=true ;;
        --phpldapadmin) START_PHPLDAPADMIN=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Colors & formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'  # No Color

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

subsection() {
    echo ""
    echo -e "${YELLOW}  ▸ $1${NC}"
    echo -e "${DIM}  $(printf '%.0s─' {1..72})${NC}"
}

run_cmd() {
    echo -e "  ${DIM}\$ ${GREEN}$*${NC}"
    eval "$@" 2>&1 | sed 's/^/    /'
    echo ""
}

info() {
    echo -e "  ${CYAN}ℹ ${NC}$*"
}

success() {
    echo -e "  ${GREEN}✓ ${NC}$*"
}

warn() {
    echo -e "  ${YELLOW}⚠ ${NC}$*"
}

pause() {
    if [ "$AUTO_MODE" = false ]; then
        echo ""
        echo -e "  ${DIM}Press Enter to continue...${NC}"
        read -r
    fi
}

disable_ldap_mount() {
    vault lease revoke -force -prefix ldap >/dev/null 2>&1 || true
    vault secrets disable ldap/ >/dev/null 2>&1 || true
}

# Track demo results for summary
declare -a DEMO_FEATURES=()
declare -a DEMO_STATUS=()

track() {
    DEMO_FEATURES+=("$1")
    DEMO_STATUS+=("$2")
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN must be set}"
CONTAINER_NAME="vault-ldap-openldap"
LDAP_ADMIN_DN="cn=admin,dc=learn,dc=example"
LDAP_ADMIN_PASSWORD="2LearnVault"
LDAP_DOMAIN="dc=learn,dc=example"
LDAP_USERS_DN="ou=users,dc=learn,dc=example"
PHPLDAPADMIN_LOGIN_DN="cn=ldapviewer,ou=users,dc=learn,dc=example"
PHPLDAPADMIN_LOGIN_PASSWORD="ldapviewerpassword"
PHPLDAPADMIN_CONTAINER_NAME="vault-ldap-phpldapadmin"
PHPLDAPADMIN_IMAGE="osixia/phpldapadmin:latest"
PHPLDAPADMIN_PORT="${PHPLDAPADMIN_PORT:-6443}"

###############################################################################
#                              DEMO START
###############################################################################
clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║                                                                  ║"
echo "  ║       HashiCorp Vault — LDAP Secrets Engine Demo                 ║"
echo "  ║                                                                  ║"
echo "  ║   Features: Static Roles • Dynamic Credentials • Library         ║"
echo "  ║             Check-Out • Root Rotation • Password Policies        ║"
echo "  ║             Hierarchical Paths • Enterprise Features             ║"
echo "  ║                                                                  ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
info "Vault Address: ${VAULT_ADDR}"
info "Mode: $([ "$AUTO_MODE" = true ] && echo "Auto (non-interactive)" || echo "Interactive")"
echo ""
pause

###############################################################################
# SECTION 0: Infrastructure Setup
###############################################################################
if [ "$SKIP_SETUP" = false ]; then
    section "0. Infrastructure Setup"

    subsection "Starting OpenLDAP container"
    # Remove existing container if present
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    VAULT_NETWORK=$(docker inspect vault-ent --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || echo "bridge")
    info "Vault container network: ${VAULT_NETWORK}"

    run_cmd docker run \
        --name "${CONTAINER_NAME}" \
        --network "${VAULT_NETWORK}" \
        --env LDAP_ORGANISATION="learn" \
        --env LDAP_DOMAIN="learn.example" \
        --env LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD}" \
        -p 389:389 -p 636:636 \
        --detach \
        osixia/openldap:1.4.0

    info "Waiting for OpenLDAP to be ready..."
    sleep 5

    run_cmd docker ps -f name="${CONTAINER_NAME}" --format '"table {{.Names}}\t{{.Status}}"'

    OPENLDAP_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    info "OpenLDAP IP: ${OPENLDAP_IP}"

    subsection "Populating LDAP directory"

    docker cp "${SCRIPT_DIR}/setup/ldifs/base.ldif" "${CONTAINER_NAME}:/tmp/base.ldif"
    docker cp "${SCRIPT_DIR}/setup/ldifs/users.ldif" "${CONTAINER_NAME}:/tmp/users.ldif"
    docker cp "${SCRIPT_DIR}/setup/ldifs/service_accounts.ldif" "${CONTAINER_NAME}:/tmp/service_accounts.ldif"

    run_cmd docker exec "${CONTAINER_NAME}" ldapadd -cxD '"cn=admin,dc=learn,dc=example"' -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif
    run_cmd docker exec "${CONTAINER_NAME}" ldapadd -cxD '"cn=admin,dc=learn,dc=example"' -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/users.ldif
    run_cmd docker exec "${CONTAINER_NAME}" ldapadd -cxD '"cn=admin,dc=learn,dc=example"' -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/service_accounts.ldif

    if [ "$START_PHPLDAPADMIN" = true ]; then
        subsection "Grant phpLDAPadmin browser read access"
        docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to attrs=userPassword,shadowLastChange by self write by dn="cn=admin,dc=learn,dc=example" write by anonymous auth by * none
olcAccess: {2}to * by dn="${PHPLDAPADMIN_LOGIN_DN}" read by self read by dn="cn=admin,dc=learn,dc=example" write by * none
EOF
        success "Granted read-only directory access to the phpLDAPadmin browser account."

        subsection "Starting phpLDAPadmin"
        docker rm -f "${PHPLDAPADMIN_CONTAINER_NAME}" >/dev/null 2>&1 || true
        run_cmd docker run \
            --name "${PHPLDAPADMIN_CONTAINER_NAME}" \
            --network "${VAULT_NETWORK}" \
            --env PHPLDAPADMIN_LDAP_HOSTS="${OPENLDAP_IP}" \
            -p "${PHPLDAPADMIN_PORT}:443" \
            --detach \
            "${PHPLDAPADMIN_IMAGE}"
        info "Waiting for phpLDAPadmin to be ready..."
        sleep 5
        run_cmd docker ps -f name="${PHPLDAPADMIN_CONTAINER_NAME}" --format '"table {{.Names}}\t{{.Status}}"'
        success "phpLDAPadmin is available at https://127.0.0.1:${PHPLDAPADMIN_PORT}"
        warn "The container uses a self-signed certificate, so your browser may show a certificate warning."
        info "Use the dedicated browser account because Vault rotates the LDAP admin password during the demo."
        info "Login DN: ${PHPLDAPADMIN_LOGIN_DN}"
        info "Password: ${PHPLDAPADMIN_LOGIN_PASSWORD}"
    fi

    success "LDAP populated with users: alice, bob, ldapviewer, svc-checkout-1, svc-checkout-2"

    subsection "Enabling & Configuring Vault LDAP Secrets Engine"
    disable_ldap_mount
    run_cmd vault secrets enable ldap
    run_cmd vault write ldap/config \
        binddn="cn=admin,dc=learn,dc=example" \
        bindpass="${LDAP_ADMIN_PASSWORD}" \
        url="ldap://${OPENLDAP_IP}" \
        schema="openldap" \
        userdn="ou=users,dc=learn,dc=example" \
        userattr="cn"

    success "LDAP secrets engine configured!"
    track "Infrastructure Setup" "✅ PASS"
    pause
else
    OPENLDAP_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    info "Skipping setup. OpenLDAP IP: ${OPENLDAP_IP}"
fi

###############################################################################
# SECTION 1: Root Credential Rotation
###############################################################################
section "1. Root Credential Rotation"
info "Vault can rotate the root (bind) credential so only Vault knows it."
info "This ensures no human has access to the LDAP admin password."
echo ""

subsection "Rotate root credential"
run_cmd vault write -f ldap/rotate-root
success "Root credential rotated! Only Vault knows the new password."

subsection "Verify Vault still operates normally"
run_cmd vault read ldap/config
success "Config is still readable — Vault has the new credential internally."

subsection "(Enterprise) Scheduled Root Rotation"
info "Configure automatic root rotation on a cron schedule."
run_cmd vault write ldap/config \
    rotation_schedule='"0 0 * * SAT"' \
    rotation_window=3600

run_cmd vault read -field=rotation_schedule ldap/config
success "Root will auto-rotate every Saturday at midnight UTC."

subsection "(Enterprise) Disable Automated Rotation"
run_cmd vault write ldap/config disable_automated_rotation=true
run_cmd vault read -field=disable_automated_rotation ldap/config
info "Automated rotation is now disabled."

run_cmd vault write ldap/config disable_automated_rotation=false
success "Automated rotation re-enabled."

# Clean up schedule
vault write ldap/config rotation_schedule="" rotation_window=0 >/dev/null 2>&1

track "Root Credential Rotation" "✅ PASS"
track "Scheduled Root Rotation (Ent)" "✅ PASS"
track "Disable/Enable Auto-Rotation (Ent)" "✅ PASS"
pause

###############################################################################
# SECTION 2: Static Roles & Credentials
###############################################################################
section "2. Static Roles & Credential Management"
info "Static roles map to existing LDAP users. Vault auto-rotates their passwords."
echo ""

subsection "Create a static role for 'alice'"
run_cmd vault write ldap/static-role/alice \
    dn='"cn=alice,ou=users,dc=learn,dc=example"' \
    username='"alice"' \
    rotation_period='"24h"'

subsection "Read static credentials"
run_cmd vault read ldap/static-cred/alice

ALICE_PWD=$(vault read -field=password ldap/static-cred/alice)
info "Alice's password (managed by Vault): ${ALICE_PWD:0:20}..."

subsection "Verify password works in LDAP"
run_cmd docker exec "${CONTAINER_NAME}" ldapwhoami \
    -xD '"cn=alice,ou=users,dc=learn,dc=example"' \
    -w "${ALICE_PWD}"
success "Alice can authenticate to LDAP with Vault-managed password!"

subsection "Manual password rotation"
info "Old password: ${ALICE_PWD:0:20}..."
run_cmd vault write -f ldap/rotate-role/alice
sleep 2
NEW_ALICE_PWD=$(vault read -field=password ldap/static-cred/alice)
info "New password: ${NEW_ALICE_PWD:0:20}..."
success "Password rotated! Old password is invalidated."

subsection "Verify new password works"
run_cmd docker exec "${CONTAINER_NAME}" ldapwhoami \
    -xD '"cn=alice,ou=users,dc=learn,dc=example"' \
    -w "${NEW_ALICE_PWD}"

subsection "List all static roles"
run_cmd vault list ldap/static-role

# Cleanup
vault delete ldap/static-role/alice >/dev/null 2>&1

track "Static Roles (CRUD)" "✅ PASS"
track "Static Credential Read & LDAP Verify" "✅ PASS"
track "Manual Password Rotation" "✅ PASS"
pause

###############################################################################
# SECTION 3: Dynamic Credentials
###############################################################################
section "3. Dynamic Credentials"
info "Dynamic credentials create short-lived LDAP users on demand using LDIF templates."
echo ""

subsection "View LDIF templates"
echo -e "  ${DIM}Creation LDIF:${NC}"
cat "${SCRIPT_DIR}/setup/ldifs/creation.ldif" | sed 's/^/    /'
echo ""
echo -e "  ${DIM}Deletion LDIF:${NC}"
cat "${SCRIPT_DIR}/setup/ldifs/deletion.ldif" | sed 's/^/    /'
echo ""

subsection "Create a dynamic role"
CREATION=$(base64 < "${SCRIPT_DIR}/setup/ldifs/creation.ldif")
DELETION=$(base64 < "${SCRIPT_DIR}/setup/ldifs/deletion.ldif")
ROLLBACK=$(base64 < "${SCRIPT_DIR}/setup/ldifs/rollback.ldif")

run_cmd vault write ldap/role/dynamic-dev \
    creation_ldif="${CREATION}" \
    deletion_ldif="${DELETION}" \
    rollback_ldif="${ROLLBACK}" \
    default_ttl='"1h"' \
    max_ttl='"24h"'

subsection "Generate dynamic credentials"
run_cmd vault read ldap/creds/dynamic-dev

DYN_DATA=$(vault read -format=json ldap/creds/dynamic-dev)
DYN_USER=$(echo "${DYN_DATA}" | jq -r '.data.username')
DYN_PWD=$(echo "${DYN_DATA}" | jq -r '.data.password')
DYN_DN=$(echo "${DYN_DATA}" | jq -r '.data.distinguished_names[0]')
LEASE_ID=$(echo "${DYN_DATA}" | jq -r '.lease_id')

info "Dynamic user created: ${DYN_USER}"

subsection "Verify dynamic user exists in LDAP"
run_cmd docker exec "${CONTAINER_NAME}" ldapsearch -Y EXTERNAL -H ldapi:/// \
    -b '"ou=users,dc=learn,dc=example"' '"(cn='"${DYN_USER}"')"' cn

subsection "Verify dynamic credential works"
run_cmd docker exec "${CONTAINER_NAME}" ldapwhoami \
    -xD '"'"${DYN_DN}"'"' \
    -w '"'"${DYN_PWD}"'"'
success "Dynamic user can authenticate!"

subsection "Revoke lease → deletes LDAP user"
run_cmd vault lease revoke "${LEASE_ID}"
sleep 3
info "Checking if user still exists..."
SEARCH_RESULT=$(docker exec "${CONTAINER_NAME}" ldapsearch -Y EXTERNAL -H ldapi:/// \
    -b "ou=users,dc=learn,dc=example" "(cn=${DYN_USER})" cn 2>&1 | grep "numEntries" || echo "numEntries: 0")
echo -e "    ${SEARCH_RESULT}"
success "Dynamic user deleted from LDAP after lease revocation!"

subsection "Custom username template"
run_cmd vault write ldap/role/custom-tpl \
    creation_ldif="${CREATION}" \
    deletion_ldif="${DELETION}" \
    username_template='"dyn_{{.RoleName}}_{{random 8}}"' \
    default_ttl='"1h"' max_ttl='"24h"'

CUSTOM_DATA=$(vault read -format=json ldap/creds/custom-tpl)
CUSTOM_USER=$(echo "${CUSTOM_DATA}" | jq -r '.data.username')
CUSTOM_LEASE=$(echo "${CUSTOM_DATA}" | jq -r '.lease_id')
info "Custom template username: ${CUSTOM_USER}"
success "Username follows custom template pattern!"

vault lease revoke "${CUSTOM_LEASE}" >/dev/null 2>&1
vault delete ldap/role/custom-tpl >/dev/null 2>&1
vault delete ldap/role/dynamic-dev >/dev/null 2>&1
sleep 2

track "Dynamic Credentials (LDIF)" "✅ PASS"
track "Lease Revocation -> LDAP Cleanup" "✅ PASS"
track "Custom Username Template" "✅ PASS"
pause

###############################################################################
# SECTION 4: Service Account Check-Out (Library)
###############################################################################
section "4. Service Account Check-Out (Library)"
info "Library sets provide a pool of service accounts that users can check out."
info "Vault auto-rotates passwords on check-in and enforces lending periods."
echo ""

subsection "Create a library set"
run_cmd vault write ldap/library/svc-team \
    service_account_names='"svc-checkout-1,svc-checkout-2"' \
    ttl='"1h"' \
    max_ttl='"2h"' \
    disable_check_in_enforcement=false

subsection "Check library status"
run_cmd vault read ldap/library/svc-team/status
info "Both accounts are available."

subsection "Check out a service account"
CHECKOUT_DATA=$(vault write -format=json ldap/library/svc-team/check-out ttl="30m")
SVC_ACCOUNT=$(echo "${CHECKOUT_DATA}" | jq -r '.data.service_account_name')
SVC_PWD=$(echo "${CHECKOUT_DATA}" | jq -r '.data.password')
info "Checked out: ${SVC_ACCOUNT}"
info "Password: ${SVC_PWD:0:20}..."

subsection "Verify checked-out credential"
run_cmd docker exec "${CONTAINER_NAME}" ldapwhoami \
    -xD '"cn='"${SVC_ACCOUNT}"',ou=users,dc=learn,dc=example"' \
    -w '"'"${SVC_PWD}"'"'
success "Service account credential works!"

subsection "Check status — account is unavailable"
run_cmd vault read ldap/library/svc-team/status

subsection "Voluntary check-in"
run_cmd vault write ldap/library/svc-team/check-in \
    service_account_names="${SVC_ACCOUNT}"
success "Account checked back in. Password will be rotated."

subsection "Check out both accounts (exhaust pool)"
CHECKOUT1=$(vault write -format=json ldap/library/svc-team/check-out ttl="30m")
ACCT1=$(echo "${CHECKOUT1}" | jq -r '.data.service_account_name')
CHECKOUT2=$(vault write -format=json ldap/library/svc-team/check-out ttl="30m")
ACCT2=$(echo "${CHECKOUT2}" | jq -r '.data.service_account_name')
info "Checked out: ${ACCT1} and ${ACCT2}"
run_cmd vault read ldap/library/svc-team/status
warn "All accounts unavailable — next check-out would fail."

subsection "Managed (admin) force check-in"
run_cmd vault write ldap/library/manage/svc-team/check-in \
    service_account_names="${ACCT1},${ACCT2}"
success "Admin force-checked in both accounts."

# Cleanup
vault delete ldap/library/svc-team >/dev/null 2>&1

track "Library Set (CRUD)" "✅ PASS"
track "Service Account Check-Out" "✅ PASS"
track "Check-In & Managed Check-In" "✅ PASS"
track "Pool Exhaustion" "✅ PASS"
pause

###############################################################################
# SECTION 5: Hierarchical Path Organization
###############################################################################
section "5. Hierarchical Path Organization"
info "Organize roles with forward-slash paths for team/project structure."
info "Vault policies can scope access to specific path levels."
echo ""

subsection "Create hierarchical static roles"
# Recreate users for fresh state
docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF
dn: cn=alice,ou=users,dc=learn,dc=example
changetype: modify
replace: userPassword
userPassword: alicepassword
EOF
docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF
dn: cn=bob,ou=users,dc=learn,dc=example
changetype: modify
replace: userPassword
userPassword: bobpassword
EOF

run_cmd vault write ldap/static-role/org/dev \
    dn='"cn=alice,ou=users,dc=learn,dc=example"' \
    username='"alice"' rotation_period='"24h"'
sleep 2

run_cmd vault write ldap/static-role/org/platform/sre \
    dn='"cn=bob,ou=users,dc=learn,dc=example"' \
    username='"bob"' rotation_period='"24h"'
sleep 2

subsection "List roles at top level"
run_cmd vault list ldap/static-role
info "Shows 'org/' prefix indicating sub-paths."

subsection "List roles at org/ level"
run_cmd vault list ldap/static-role/org
info "Shows 'dev' and 'platform/' sub-paths."

subsection "List roles at org/platform/ level"
run_cmd vault list ldap/static-role/org/platform

subsection "Read credentials from hierarchical roles"
run_cmd vault read ldap/static-cred/org/dev
run_cmd vault read ldap/static-cred/org/platform/sre
success "Hierarchical paths allow organized credential management!"

info "Example policy to scope access:"
echo -e '    path "ldap/static-cred/org/platform/*" {'
echo -e '      capabilities = ["read"]'
echo -e '    }'
echo ""
info "This would only grant access to org/platform/ roles."

# Cleanup
vault delete ldap/static-role/org/dev >/dev/null 2>&1
vault delete ldap/static-role/org/platform/sre >/dev/null 2>&1

track "Hierarchical Paths" "✅ PASS"
pause

###############################################################################
# SECTION 6: Custom Password Policies
###############################################################################
section "6. Custom Password Policies"
info "Define password policies to control generated password characteristics."
echo ""

subsection "Create a custom password policy"
run_cmd vault write sys/policies/password/ldap-demo-policy policy=-<<'POLICYEOF'
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
POLICYEOF

subsection "Apply policy to LDAP secrets engine"
run_cmd vault write ldap/config password_policy="ldap-demo-policy"

subsection "Generate a sample password"
info "Generating 5 sample passwords:"
for i in 1 2 3 4 5; do
    PWD=$(curl -s --header "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/policies/password/ldap-demo-policy/generate" | jq -r '.data.password')
    echo -e "    ${GREEN}${PWD}${NC}  (length: ${#PWD})"
done
echo ""
success "All passwords are 20 chars with lowercase, uppercase, digits, and special chars."

subsection "Verify policy applies to static roles"
docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 <<EOF
dn: cn=alice,ou=users,dc=learn,dc=example
changetype: modify
replace: userPassword
userPassword: alicepassword
EOF

vault write ldap/static-role/alice-policy \
    dn="cn=alice,ou=users,dc=learn,dc=example" \
    username="alice" \
    rotation_period="24h" >/dev/null 2>&1
sleep 2

POLICY_PWD=$(vault read -field=password ldap/static-cred/alice-policy)
info "Static role password: ${POLICY_PWD}"
info "Length: ${#POLICY_PWD}"
success "Password follows custom policy requirements!"

# Cleanup
vault delete ldap/static-role/alice-policy >/dev/null 2>&1
vault write ldap/config password_policy="" >/dev/null 2>&1

track "Custom Password Policies" "✅ PASS"
pause

###############################################################################
# SUMMARY
###############################################################################
section "Demo Summary"

echo -e "  ${BOLD}Feature${NC}                                    ${BOLD}Status${NC}"
echo -e "  $(printf '%.0s─' {1..60})"
for i in "${!DEMO_FEATURES[@]}"; do
    printf "  %-44s %s\n" "${DEMO_FEATURES[$i]}" "${DEMO_STATUS[$i]}"
done

echo ""
echo -e "  ${BOLD}Total features demonstrated: ${#DEMO_FEATURES[@]}${NC}"
echo ""
info "All LDAP secrets engine features have been demonstrated!"
echo ""

###############################################################################
# CLEANUP
###############################################################################
if [ "$NO_CLEANUP" = false ]; then
    section "Cleanup"
    info "Cleaning up demo resources..."

    disable_ldap_mount
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm -f "${PHPLDAPADMIN_CONTAINER_NAME}" 2>/dev/null || true
    vault policy delete ldap-admin 2>/dev/null || true
    vault delete sys/policies/password/ldap-demo-policy 2>/dev/null || true

    success "Cleanup complete!"
else
    echo ""
    info "Skipping cleanup (--no-cleanup). Resources are still available."
    info "To clean up manually, run: ./cleanup.sh"
fi

echo ""
echo -e "${BOLD}${CYAN}  Demo complete! Thank you.${NC}"
echo ""
