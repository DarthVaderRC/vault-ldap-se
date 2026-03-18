"""
Test 06: Hierarchical Paths

Covers:
- Creating static roles with hierarchical names (org/dev, org/platform/sre)
- Listing roles at specific path levels
- Demonstrating policy-based access scoping with paths
"""
import time

import pytest

from conftest import (
    MOUNT_POINT,
    recreate_service_account,
)


@pytest.fixture(scope="module")
def hierarchical_roles(vault_client, ensure_ldap_engine):
    """Create hierarchical static roles and clean up after."""
    recreate_service_account("svc-account-1", "svcaccount1password")
    recreate_service_account("svc-account-2", "svcaccount2password")

    vault_client.write(
        f"{MOUNT_POINT}/static-role/org/dev",
        dn="cn=svc-account-1,ou=ServiceAccounts,dc=hashicups,dc=local",
        username="svc-account-1",
        rotation_period="24h",
    )
    time.sleep(2)

    vault_client.write(
        f"{MOUNT_POINT}/static-role/org/platform/sre",
        dn="cn=svc-account-2,ou=ServiceAccounts,dc=hashicups,dc=local",
        username="svc-account-2",
        rotation_period="24h",
    )
    time.sleep(2)
    yield

    # Cleanup
    for role in ["org/dev", "org/platform/sre"]:
        try:
            vault_client.delete(f"{MOUNT_POINT}/static-role/{role}")
        except Exception:
            pass


class TestHierarchicalStaticRoles:
    """Test hierarchical path organization for static roles."""

    def test_list_top_level_roles(self, vault_client, hierarchical_roles):
        """List roles at the top level shows 'org/' prefix."""
        resp = vault_client.list(f"{MOUNT_POINT}/static-role")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert "org/" in keys

    def test_list_org_level_roles(self, vault_client, hierarchical_roles):
        """List roles at the org/ level."""
        resp = vault_client.list(f"{MOUNT_POINT}/static-role/org")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert "dev" in keys
        assert "platform/" in keys

    def test_list_platform_level_roles(self, vault_client, hierarchical_roles):
        """List roles at the org/platform/ level."""
        resp = vault_client.list(f"{MOUNT_POINT}/static-role/org/platform")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert "sre" in keys

    def test_read_hierarchical_role(self, vault_client, hierarchical_roles):
        """Read a specific hierarchical role."""
        resp = vault_client.read(f"{MOUNT_POINT}/static-role/org/dev")
        assert resp is not None
        assert resp["data"]["username"] == "svc-account-1"

        resp = vault_client.read(f"{MOUNT_POINT}/static-role/org/platform/sre")
        assert resp is not None
        assert resp["data"]["username"] == "svc-account-2"

    def test_read_hierarchical_credentials(self, vault_client, hierarchical_roles):
        """Read credentials from hierarchical roles."""
        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/org/dev")
        assert resp is not None
        assert "password" in resp["data"]

        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/org/platform/sre")
        assert resp is not None
        assert "password" in resp["data"]
