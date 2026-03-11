#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="vault-ldap-openldap"
LDAP_ORG="learn"
LDAP_DOMAIN="learn.example"
LDAP_ADMIN_PASSWORD="2LearnVault"
LDAP_IMAGE="osixia/openldap:1.4.0"

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
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=learn,dc=example" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif

echo ""
echo "=== Adding users (alice, bob) ==="
docker cp "${SCRIPT_DIR}/ldifs/users.ldif" "${CONTAINER_NAME}:/tmp/users.ldif"
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=learn,dc=example" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/users.ldif

echo ""
echo "=== Adding service accounts ==="
docker cp "${SCRIPT_DIR}/ldifs/service_accounts.ldif" "${CONTAINER_NAME}:/tmp/service_accounts.ldif"
docker exec "${CONTAINER_NAME}" ldapadd -cxD "cn=admin,dc=learn,dc=example" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/service_accounts.ldif

echo ""
echo "=== Verifying LDAP entries ==="
docker exec "${CONTAINER_NAME}" ldapsearch -xD "cn=admin,dc=learn,dc=example" -w "${LDAP_ADMIN_PASSWORD}" -b "dc=learn,dc=example" "(objectClass=person)" cn

echo ""
echo "=== OpenLDAP setup complete ==="
echo "OpenLDAP IP: ${OPENLDAP_IP}"
echo "Admin DN: cn=admin,dc=learn,dc=example"
echo "Admin Password: ${LDAP_ADMIN_PASSWORD}"
echo "Base DN: dc=learn,dc=example"
