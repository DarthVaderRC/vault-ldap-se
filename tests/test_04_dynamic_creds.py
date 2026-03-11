"""
Test 04: Dynamic Credentials

Covers:
- Creating a dynamic role with LDIF templates
- Generating dynamic credentials
- Verifying the dynamically created LDAP user can bind
- Lease revocation deletes the LDAP user
- Custom username_template
- TTL behavior (default_ttl, max_ttl)
- Listing dynamic roles
"""
import base64
import os
import time

import pytest

from conftest import (
    LDAP_HOST_URL,
    LDAP_USERS_DN,
    MOUNT_POINT,
    PROJECT_DIR,
    ldap_bind_check,
    ldap_entry_exists,
    wait_for_condition,
)


def read_ldif_file(filename):
    """Read an LDIF file and return base64-encoded content."""
    path = os.path.join(PROJECT_DIR, "setup", "ldifs", filename)
    with open(path) as f:
        content = f.read()
    return base64.b64encode(content.encode()).decode()


@pytest.fixture(scope="module")
def dynamic_role(vault_client, ensure_ldap_engine):
    """Create a dynamic role for testing and clean up after."""
    creation_ldif = read_ldif_file("creation.ldif")
    deletion_ldif = read_ldif_file("deletion.ldif")
    rollback_ldif = read_ldif_file("rollback.ldif")

    vault_client.write(
        f"{MOUNT_POINT}/role/dynamic-dev",
        creation_ldif=creation_ldif,
        deletion_ldif=deletion_ldif,
        rollback_ldif=rollback_ldif,
        default_ttl="1h",
        max_ttl="24h",
    )
    yield "dynamic-dev"
    try:
        vault_client.delete(f"{MOUNT_POINT}/role/dynamic-dev")
    except Exception:
        pass


class TestDynamicRoleCRUD:
    """Test dynamic role create, read, list, delete."""

    def test_create_dynamic_role(self, vault_client, dynamic_role):
        """Dynamic role exists and is readable."""
        resp = vault_client.read(f"{MOUNT_POINT}/role/{dynamic_role}")
        assert resp is not None
        data = resp["data"]
        assert data["default_ttl"] == 3600
        assert data["max_ttl"] == 86400

    def test_list_dynamic_roles(self, vault_client, dynamic_role):
        """List all dynamic roles."""
        resp = vault_client.list(f"{MOUNT_POINT}/role")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert dynamic_role in keys

    def test_read_dynamic_role(self, vault_client, dynamic_role):
        """Read a specific dynamic role."""
        resp = vault_client.read(f"{MOUNT_POINT}/role/{dynamic_role}")
        assert resp is not None
        assert "creation_ldif" in resp["data"]
        assert "deletion_ldif" in resp["data"]


class TestDynamicCredentialGeneration:
    """Test dynamic credential generation and LDAP verification."""

    def test_generate_and_verify_dynamic_credentials(self, vault_client, dynamic_role):
        """Generate dynamic credentials, verify LDAP bind, then revoke."""
        # Generate credentials
        resp = vault_client.read(f"{MOUNT_POINT}/creds/{dynamic_role}")
        assert resp is not None
        data = resp["data"]
        assert "username" in data
        assert "password" in data
        assert "distinguished_names" in data
        assert len(data["password"]) > 0

        username = data["username"]
        password = data["password"]
        dn = data["distinguished_names"][0]
        lease_id = resp["lease_id"]

        # Verify LDAP bind works
        assert ldap_bind_check(dn, password), \
            f"Dynamic credential should allow LDAP bind for {dn}"

        # Verify user exists in LDAP
        assert ldap_entry_exists(username), \
            f"Dynamic user {username} should exist in LDAP"

        # Revoke the lease
        vault_client.sys.revoke_lease(lease_id)
        time.sleep(3)

        # User should be deleted from LDAP
        assert not ldap_entry_exists(username), \
            f"Dynamic user {username} should be deleted after revocation"


class TestDynamicCredentialTTL:
    """Test TTL behavior for dynamic credentials."""

    def test_default_ttl(self, vault_client, ensure_ldap_engine):
        """Verify credentials respect default_ttl."""
        creation_ldif = read_ldif_file("creation.ldif")
        deletion_ldif = read_ldif_file("deletion.ldif")

        vault_client.write(
            f"{MOUNT_POINT}/role/ttl-test",
            creation_ldif=creation_ldif,
            deletion_ldif=deletion_ldif,
            default_ttl="300s",
            max_ttl="600s",
        )

        resp = vault_client.read(f"{MOUNT_POINT}/creds/ttl-test")
        assert 250 <= resp["lease_duration"] <= 350, \
            f"Lease duration {resp['lease_duration']} should be ~300s"

        # Cleanup
        vault_client.sys.revoke_lease(resp["lease_id"])
        time.sleep(2)
        vault_client.delete(f"{MOUNT_POINT}/role/ttl-test")


class TestCustomUsernameTemplate:
    """Test custom username template for dynamic roles."""

    def test_custom_username_template(self, vault_client, ensure_ldap_engine):
        """Create a role with custom username template and verify."""
        creation_ldif = read_ldif_file("creation.ldif")
        deletion_ldif = read_ldif_file("deletion.ldif")

        vault_client.write(
            f"{MOUNT_POINT}/role/custom-template",
            creation_ldif=creation_ldif,
            deletion_ldif=deletion_ldif,
            username_template="dyn_{{.RoleName}}_{{random 8}}",
            default_ttl="1h",
            max_ttl="24h",
        )

        resp = vault_client.read(f"{MOUNT_POINT}/creds/custom-template")
        username = resp["data"]["username"]

        assert username.startswith("dyn_custom-template_"), \
            f"Username '{username}' should start with 'dyn_custom-template_'"
        assert len(username) > len("dyn_custom-template_")

        # Cleanup
        vault_client.sys.revoke_lease(resp["lease_id"])
        time.sleep(2)
        vault_client.delete(f"{MOUNT_POINT}/role/custom-template")
