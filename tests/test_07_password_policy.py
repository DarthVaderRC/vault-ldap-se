"""
Test 07: Password Policies

Covers:
- Creating a custom password policy
- Applying it to the LDAP secrets engine
- Verifying generated passwords conform to the policy
- Testing policy with static and dynamic credentials
"""
import base64
import os
import re
import time

import pytest

from conftest import (
    LDAP_USERS_DN,
    LDAP_URL,
    MOUNT_POINT,
    PROJECT_DIR,
    ldap_bind_check,
    recreate_ldap_user,
)


CUSTOM_POLICY = """
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
"""


def read_ldif_file(filename):
    path = os.path.join(PROJECT_DIR, "setup", "ldifs", filename)
    with open(path) as f:
        content = f.read()
    return base64.b64encode(content.encode()).decode()


class TestPasswordPolicyCreation:
    """Test creating and applying password policies."""

    def test_create_password_policy(self, vault_client, ensure_ldap_engine):
        """Create a custom password policy."""
        vault_client.write(
            "sys/policies/password/ldap-custom-policy",
            policy=CUSTOM_POLICY,
        )

        resp = vault_client.read("sys/policies/password/ldap-custom-policy")
        assert resp is not None
        assert "policy" in resp["data"]

    def test_apply_policy_to_engine(self, vault_client):
        """Apply the password policy to the LDAP secrets engine."""
        vault_client.write(
            f"{MOUNT_POINT}/config",
            password_policy="ldap-custom-policy",
        )

        resp = vault_client.read(f"{MOUNT_POINT}/config")
        # password_policy may not be directly visible in config read,
        # but the effect is testable through credential generation

    def test_generate_password_with_policy(self, vault_client):
        """Generate a password and verify it meets the policy."""
        # Use requests directly since hvac may not handle this path well
        import requests
        url = f"{vault_client._adapter.base_uri}/v1/sys/policies/password/ldap-custom-policy/generate"
        headers = {"X-Vault-Token": vault_client.token}
        r = requests.get(url, headers=headers)
        assert r.status_code == 200, f"Generate password failed: {r.text}"
        password = r.json()["data"]["password"]

        # Verify length
        assert len(password) == 20, f"Password length {len(password)} should be 20"

        # Verify character classes
        assert re.search(r"[a-z]", password), "Should contain lowercase"
        assert re.search(r"[A-Z]", password), "Should contain uppercase"
        assert re.search(r"[0-9]", password), "Should contain digit"
        assert re.search(r"[!@#$%^&*]", password), "Should contain special char"


class TestPasswordPolicyWithStaticRole:
    """Test that password policy affects static role passwords."""

    def test_static_role_respects_policy(self, vault_client, ensure_ldap_engine):
        """Verify static role passwords follow the configured policy."""
        recreate_ldap_user("alice", "alicepassword")

        # Ensure any prior role is cleaned up
        try:
            vault_client.delete(f"{MOUNT_POINT}/static-role/alice")
            time.sleep(1)
        except Exception:
            pass

        vault_client.write(
            f"{MOUNT_POINT}/static-role/alice-policy",
            dn="cn=alice,ou=users,dc=learn,dc=example",
            username="alice",
            rotation_period="24h",
        )

        time.sleep(2)

        resp = vault_client.read(f"{MOUNT_POINT}/static-cred/alice-policy")
        password = resp["data"]["password"]

        # Verify the password meets policy requirements
        assert len(password) == 20, f"Password length {len(password)} should be 20"
        assert re.search(r"[a-z]", password), "Should contain lowercase"
        assert re.search(r"[A-Z]", password), "Should contain uppercase"
        assert re.search(r"[0-9]", password), "Should contain digit"
        assert re.search(r"[!@#$%^&*]", password), "Should contain special char"

        # Cleanup
        vault_client.delete(f"{MOUNT_POINT}/static-role/alice-policy")


class TestPasswordPolicyWithDynamicRole:
    """Test that password policy affects dynamic role passwords."""

    def test_dynamic_role_respects_policy(self, vault_client, ensure_ldap_engine):
        """Verify dynamic credentials follow the configured policy."""
        creation_ldif = read_ldif_file("creation.ldif")
        deletion_ldif = read_ldif_file("deletion.ldif")

        vault_client.write(
            f"{MOUNT_POINT}/role/policy-test",
            creation_ldif=creation_ldif,
            deletion_ldif=deletion_ldif,
            default_ttl="1h",
            max_ttl="24h",
        )

        resp = vault_client.read(f"{MOUNT_POINT}/creds/policy-test")
        password = resp["data"]["password"]

        # Verify the password meets policy requirements
        assert len(password) == 20, f"Password length {len(password)} should be 20"
        assert re.search(r"[a-z]", password), "Should contain lowercase"
        assert re.search(r"[A-Z]", password), "Should contain uppercase"
        assert re.search(r"[0-9]", password), "Should contain digit"
        assert re.search(r"[!@#$%^&*]", password), "Should contain special char"

        # Cleanup
        vault_client.sys.revoke_lease(resp["lease_id"])
        time.sleep(2)
        vault_client.delete(f"{MOUNT_POINT}/role/policy-test")


class TestPasswordPolicyCleanup:
    """Clean up password policy configuration."""

    def test_remove_password_policy_from_engine(self, vault_client):
        """Remove the password policy from the engine config."""
        vault_client.write(
            f"{MOUNT_POINT}/config",
            password_policy="",
        )
