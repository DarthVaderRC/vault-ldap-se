#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="vault-ldap-openldap"
LDAP_ORG="HashiCups"
LDAP_DOMAIN="hashicups.local"
LDAP_ADMIN_PASSWORD="2LearnVault"
LDAP_IMAGE="osixia/openldap:1.4.0"
PHPLDAPADMIN_LOGIN_DN="cn=ldapviewer,ou=ServiceAccounts,dc=hashicups,dc=local"
PHPLDAPADMIN_LOGIN_PASSWORD="ldapviewerpassword"
PHPLDAPADMIN_CONTAINER_NAME="vault-ldap-phpldapadmin"
PHPLDAPADMIN_IMAGE="osixia/phpldapadmin:latest"
PHPLDAPADMIN_PORT="${PHPLDAPADMIN_PORT:-6443}"
START_PHPLDAPADMIN=false

for arg in "$@"; do
    case "$arg" in
        --phpldapadmin) START_PHPLDAPADMIN=true ;;
    esac
done

echo "=== Setting up OpenLDAP container ==="

# Stop existing container if running
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing existing container ${CONTAINER_NAME}..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# Get vault-ent network
VAULT_NETWORK=$(docker inspect vault-ent --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || echo "bridge")
echo "Vault container network: ${VAULT_NETWORK}"

# Start OpenLDAP container on the same network
echo "Starting OpenLDAP container..."
docker run \
    --name "${CONTAINER_NAME}" \
    --network "${VAULT_NETWORK}" \
    --env LDAP_ORGANISATION="${LDAP_ORG}" \
    --env LDAP_DOMAIN="${LDAP_DOMAIN}" \
    --env LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD}" \
    -p 389:389 \
    -p 636:636 \
    --detach \
    "${LDAP_IMAGE}"

echo "Waiting for OpenLDAP to be ready..."
sleep 5

# Verify container is running
docker ps -f name="${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}"

# Get OpenLDAP container IP
OPENLDAP_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "OpenLDAP container IP: ${OPENLDAP_IP}"

# Add LDAP data using ldapadd inside the container
echo ""
echo "=== Populating OpenLDAP with base structure ==="
docker cp "${SCRIPT_DIR}/ldifs/base.ldif" "${CONTAINER_NAME}:/tmp/base.ldif"
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=hashicups,dc=local" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif

echo ""
echo "=== Adding seeded static accounts (svc-account-1, svc-account-2, ldapviewer) ==="
docker cp "${SCRIPT_DIR}/ldifs/seed_entries.ldif" "${CONTAINER_NAME}:/tmp/seed_entries.ldif"
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=hashicups,dc=local" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/seed_entries.ldif

echo ""
echo "=== Adding library accounts ==="
docker cp "${SCRIPT_DIR}/ldifs/library_accounts.ldif" "${CONTAINER_NAME}:/tmp/library_accounts.ldif"
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=hashicups,dc=local" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/library_accounts.ldif

echo ""
echo "=== Verifying LDAP entries ==="
docker exec "${CONTAINER_NAME}" ldapsearch -xD "cn=admin,dc=hashicups,dc=local" -w "${LDAP_ADMIN_PASSWORD}" -b "dc=hashicups,dc=local" "(objectClass=person)" cn

if [ "$START_PHPLDAPADMIN" = true ]; then
    echo ""
    echo "=== Granting phpLDAPadmin browser read access ==="
    docker exec -i "${CONTAINER_NAME}" ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to attrs=userPassword,shadowLastChange by self write by dn="cn=admin,dc=hashicups,dc=local" write by anonymous auth by * none
olcAccess: {2}to * by dn="${PHPLDAPADMIN_LOGIN_DN}" read by self read by dn="cn=admin,dc=hashicups,dc=local" write by * none
EOF
    echo "Granted read-only directory access to the phpLDAPadmin browser account."

    echo ""
    echo "=== Starting phpLDAPadmin ==="
    docker rm -f "${PHPLDAPADMIN_CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker run \
        --name "${PHPLDAPADMIN_CONTAINER_NAME}" \
        --network "${VAULT_NETWORK}" \
        --env PHPLDAPADMIN_LDAP_HOSTS="${OPENLDAP_IP}" \
        -p "${PHPLDAPADMIN_PORT}:443" \
        --detach \
        "${PHPLDAPADMIN_IMAGE}"
    echo "Waiting for phpLDAPadmin to be ready..."
    sleep 5
    docker ps -f name="${PHPLDAPADMIN_CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}"
    echo "phpLDAPadmin URL: https://127.0.0.1:${PHPLDAPADMIN_PORT}"
    echo "The container uses a self-signed certificate, so your browser may show a certificate warning."
    echo "Use the dedicated browser account because Vault rotates the LDAP admin password during the demo."
    echo "phpLDAPadmin Login DN: ${PHPLDAPADMIN_LOGIN_DN}"
    echo "phpLDAPadmin Password: ${PHPLDAPADMIN_LOGIN_PASSWORD}"
fi

echo ""
echo "=== OpenLDAP setup complete ==="
echo "OpenLDAP IP: ${OPENLDAP_IP}"
echo "Admin DN: cn=admin,dc=hashicups,dc=local"
echo "Admin Password: ${LDAP_ADMIN_PASSWORD}"
echo "Base DN: dc=hashicups,dc=local"
