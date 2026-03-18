"""
Test 03: Static Roles and Credentials

Covers:
- Creating static roles mapped to existing LDAP service accounts
- Reading static credentials
- Manual password rotation
- Automatic password rotation (short rotation_period)
- Password verification against LDAP (ldap bind)
- Listing static roles
- Deleting static roles
- skip_import_rotation behavior
"""
import time

import pytest

from conftest import (
    LDAP_HOST_URL,
    LDAP_SERVICE_ACCOUNTS_DN,
    MOUNT_POINT,
    ldap_bind_check,
    recreate_service_account,
    wait_for_condition,
)


class TestStaticRoleCRUD:
    """Test static role create, read, list, delete operations."""

    def test_create_static_role(self, vault_client, ensure_ldap_engine):
        """Create a static role for svc-account-1."""
        recreate_service_account("svc-account-1", "svcaccount1password")

        vault_client.write(
            f"{MOUNT_POINT}/static-role/svc-account-1",
            dn="cn=svc-account-1,ou=ServiceAccounts,dc=hashicups,dc=local",
            username="svc-account-1",
            rotation_period="24h",
        )

        resp = vault_client.read(f"{MOUNT_POINT}/static-role/svc-account-1")
        assert resp is not None
        data = resp["data"]
        assert data["username"] == "svc-account-1"
        assert data["dn"] == "cn=svc-account-1,ou=ServiceAccounts,dc=hashicups,dc=local"

    def test_read_static_credentials(self, vault_client):
        """Read credentials from the svc-account-1 static role."""
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-1")
        assert resp is not None
        data = resp["data"]
        assert "password" in data
        assert len(data["password"]) > 0
        assert data["username"] == "svc-account-1"
        assert "ttl" in data
        assert "last_vault_rotation" in data

    def test_static_credential_works_in_ldap(self, vault_client):
        """Verify the Vault-managed password works for LDAP bind."""
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-1")
        password = resp["data"]["password"]
        dn = "cn=svc-account-1,ou=ServiceAccounts,dc=hashicups,dc=local"

        assert ldap_bind_check(dn, password), \
            "Static credential should work for LDAP bind"

    def test_list_static_roles(self, vault_client):
        """List all static roles."""
        resp = vault_client.list(f"{MOUNT_POINT}/static-role")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert "svc-account-1" in keys

    def test_create_second_static_role(self, vault_client):
        """Create a second static role for svc-account-2."""
        recreate_service_account("svc-account-2", "svcaccount2password")

        vault_client.write(
            f"{MOUNT_POINT}/static-role/svc-account-2",
            dn="cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local",
            username="svc-account-2",
            rotation_period="24h",
        )

        resp = vault_client.list(f"{MOUNT_POINT}/static-role")
        keys = resp["data"]["keys"]
        assert "svc-account-1" in keys
        assert "svc-account-2" in keys

    def test_delete_static_role(self, vault_client):
        """Delete the svc-account-2 static role."""
        vault_client.delete(f"{MOUNT_POINT}/static-role/svc-account-2")

        resp = vault_client.list(f"{MOUNT_POINT}/static-role")
        keys = resp["data"]["keys"]
        assert "svc-account-2" not in keys


class TestStaticRoleRotation:
    """Test static role password rotation."""

    def test_manual_rotation(self, vault_client, ensure_ldap_engine):
        """Manually rotate a static role password."""
        # Get current password
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-1")
        old_password = resp["data"]["password"]

        # Trigger manual rotation
        vault_client.write(f"{MOUNT_POINT}/rotate-role/svc-account-1")
        time.sleep(2)

        # Get new password
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-1")
        new_password = resp["data"]["password"]

        assert new_password != old_password, "Password should change after manual rotation"

        # Verify new password works
        dn = "cn=svc-account-1,ou=ServiceAccounts,dc=hashicups,dc=local"
        assert ldap_bind_check(dn, new_password), "New password should work"
        assert not ldap_bind_check(dn, old_password), "Old password should not work"

    def test_last_password_field(self, vault_client):
        """Verify last_password is tracked after rotation."""
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-1")
        data = resp["data"]
        # After rotation, last_password should be populated
        assert "last_password" in data

    def test_auto_rotation_short_period(self, vault_client):
        """Test automatic rotation with a short rotation_period."""
        recreate_service_account("svc-account-2", "svcaccount2password")

        # Create role with very short rotation period
        vault_client.write(
            f"{MOUNT_POINT}/static-role/svc-account-2-autorotate",
            dn="cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local",
            username="svc-account-2",
            rotation_period="10s",
        )

        # Get initial password
        time.sleep(2)
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-2-autorotate")
        initial_password = resp["data"]["password"]

        # Wait for auto-rotation
        time.sleep(15)

        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/svc-account-2-autorotate")
        rotated_password = resp["data"]["password"]

        assert rotated_password != initial_password, \
            "Password should auto-rotate after rotation_period"

        # Verify rotated password works
        dn = "cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local"
        assert ldap_bind_check(dn, rotated_password), "Auto-rotated password should work"

        # Cleanup
        vault_client.delete(f"{MOUNT_POINT}/static-role/svc-account-2-autorotate")


class TestSkipImportRotation:
    """Test skip_import_rotation behavior."""

    def test_skip_import_rotation(self, vault_client, ensure_ldap_engine):
        """When skip_import_rotation=true, Vault should not rotate on role creation."""
        known_password = "svcaccount2knownpass"
        recreate_service_account("svc-account-2", known_password)

        vault_client.write(
            f"{MOUNT_POINT}/static-role/svc-account-2-skip",
            dn="cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local",
            username="svc-account-2",
            rotation_period="24h",
            skip_import_rotation=True,
        )

        time.sleep(2)

        # The original password should still work since rotation was skipped
        dn = "cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local"
        assert ldap_bind_check(dn, known_password), \
            "Original password should still work with skip_import_rotation=True"

        # Cleanup
        vault_client.delete(f"{MOUNT_POINT}/static-role/svc-account-2-skip")


class TestStaticRoleCleanup:
    """Clean up static roles to avoid conflicts with later tests."""

    def test_cleanup_primary_static_role(self, vault_client):
        """Remove svc-account-1 static role to avoid username conflicts in later tests."""
        try:
            vault_client.delete(f"{MOUNT_POINT}/static-role/svc-account-1")
        except Exception:
            pass
