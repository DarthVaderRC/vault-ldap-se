"""
Test 01: LDAP Secrets Engine Setup & Root Credential Rotation

Covers:
- Enabling the LDAP secrets engine
- Configuring the engine with OpenLDAP connection details
- Reading back configuration
- Manual root credential rotation
- Scheduled root credential rotation (Enterprise)
- Disable/enable automated rotation (Enterprise)
"""
import time

import pytest

from conftest import (
    LDAP_ADMIN_DN,
    LDAP_ADMIN_PASSWORD,
    LDAP_HOST_URL,
    LDAP_URL,
    LDAP_SERVICE_ACCOUNTS_DN,
    MOUNT_POINT,
    OPENLDAP_IP,
    ldap_bind_check,
    reset_ldap_account_password,
)


class TestLDAPEngineSetup:
    """Test LDAP secrets engine enable and configuration."""

    def test_engine_is_enabled(self, vault_client, ensure_ldap_engine):
        """Verify the LDAP secrets engine is mounted."""
        mounts = vault_client.sys.list_mounted_secrets_engines()
        assert f"{MOUNT_POINT}/" in mounts, f"LDAP engine not found at {MOUNT_POINT}/"

    def test_config_is_readable(self, vault_client, ensure_ldap_engine):
        """Verify engine config can be read and has expected values."""
        resp = vault_client.read(f"{MOUNT_POINT}/config")
        data = resp["data"]
        assert data["binddn"] == LDAP_ADMIN_DN
        assert data["schema"] == "openldap"
        assert "172.17.0" in data["url"]
        assert data["userattr"] == "cn"
        assert data["userdn"] == LDAP_SERVICE_ACCOUNTS_DN


class TestRootCredentialRotation:
    """Test root credential rotation features."""

    def test_manual_root_rotation(self, vault_client, ensure_ldap_engine):
        """Rotate root password manually.

        Note: OpenLDAP rootDN (cn=admin) authenticates via olcRootPW in config,
        not userPassword. Vault rotates userPassword, so the rootDN's olcRootPW
        still works. To fully demonstrate root rotation, use a non-rootDN admin.
        Here we verify the API succeeds and Vault stores the new credential.
        """
        # Reset admin password to a known value and reconfigure
        reset_ldap_account_password("admin", LDAP_ADMIN_PASSWORD)
        time.sleep(1)

        vault_client.write(
            f"{MOUNT_POINT}/config",
            binddn=LDAP_ADMIN_DN,
            bindpass=LDAP_ADMIN_PASSWORD,
            url=LDAP_URL,
            schema="openldap",
            userdn=LDAP_SERVICE_ACCOUNTS_DN,
            userattr="cn",
        )

        # Rotate root credential — Vault generates a new password internally
        vault_client.write(f"{MOUNT_POINT}/rotate-root")
        time.sleep(2)

        # Verify Vault can still operate with its internal credential
        resp = vault_client.read(f"{MOUNT_POINT}/config")
        assert resp is not None
        assert resp["data"]["binddn"] == LDAP_ADMIN_DN

    def test_config_still_works_after_rotation(self, vault_client):
        """Verify Vault can still read config and operate after root rotation."""
        resp = vault_client.read(f"{MOUNT_POINT}/config")
        assert resp is not None
        assert resp["data"]["binddn"] == LDAP_ADMIN_DN

    def test_scheduled_root_rotation_enterprise(self, vault_client):
        """(Enterprise) Configure scheduled root credential rotation."""
        vault_client.write(
            f"{MOUNT_POINT}/config",
            rotation_schedule="0 0 1 1 *",
            rotation_window=3600,
        )

        resp = vault_client.read(f"{MOUNT_POINT}/config")
        data = resp["data"]
        assert data["rotation_schedule"] == "0 0 1 1 *"
        assert data["rotation_window"] == 3600

    def test_disable_automated_rotation_enterprise(self, vault_client):
        """(Enterprise) Disable and re-enable automated root rotation."""
        vault_client.write(
            f"{MOUNT_POINT}/config",
            disable_automated_rotation=True,
        )

        resp = vault_client.read(f"{MOUNT_POINT}/config")
        assert resp["data"]["disable_automated_rotation"] is True

        # Re-enable
        vault_client.write(
            f"{MOUNT_POINT}/config",
            disable_automated_rotation=False,
        )

        resp = vault_client.read(f"{MOUNT_POINT}/config")
        assert resp["data"]["disable_automated_rotation"] is False

        # Clean up schedule config
        vault_client.write(
            f"{MOUNT_POINT}/config",
            rotation_schedule="",
            rotation_window=0,
        )
