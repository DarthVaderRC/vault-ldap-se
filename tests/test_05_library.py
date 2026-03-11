"""
Test 05: Service Account Check-Out (Library)

Covers:
- Creating a library set of service accounts
- Checking out a service account
- Verifying checked-out credentials work in LDAP
- Checking library set status (available/unavailable)
- Voluntary check-in
- Managed check-in (force check-in by admin)
- disable_check_in_enforcement
- Listing library sets
- Deleting library sets
"""
import time

import pytest

from conftest import (
    LDAP_HOST_URL,
    LDAP_USERS_DN,
    MOUNT_POINT,
    ldap_bind_check,
    recreate_ldap_user,
)


@pytest.fixture(scope="module")
def library_set(vault_client, ensure_ldap_engine):
    """Create a library set for testing and clean up after."""
    recreate_ldap_user("svc-checkout-1", "svcpassword1")
    recreate_ldap_user("svc-checkout-2", "svcpassword2")

    vault_client.write(
        f"{MOUNT_POINT}/library/svc-team",
        service_account_names=["svc-checkout-1", "svc-checkout-2"],
        ttl="1h",
        max_ttl="2h",
        disable_check_in_enforcement=False,
    )
    yield "svc-team"
    # Force check-in all accounts then delete
    try:
        vault_client.write(
            f"{MOUNT_POINT}/library/manage/svc-team/check-in",
            service_account_names=["svc-checkout-1", "svc-checkout-2"],
        )
    except Exception:
        pass
    try:
        vault_client.delete(f"{MOUNT_POINT}/library/svc-team")
    except Exception:
        pass


class TestLibrarySetCRUD:
    """Test library set create, read, list, delete."""

    def test_create_library_set(self, vault_client, library_set):
        """Library set exists and is readable."""
        resp = vault_client.read(f"{MOUNT_POINT}/library/{library_set}")
        assert resp is not None
        data = resp["data"]
        assert "svc-checkout-1" in data["service_account_names"]
        assert "svc-checkout-2" in data["service_account_names"]

    def test_list_library_sets(self, vault_client, library_set):
        """List all library sets."""
        resp = vault_client.list(f"{MOUNT_POINT}/library")
        assert resp is not None
        keys = resp["data"]["keys"]
        assert library_set in keys

    def test_read_library_set(self, vault_client, library_set):
        """Read a specific library set."""
        resp = vault_client.read(f"{MOUNT_POINT}/library/{library_set}")
        assert resp is not None
        data = resp["data"]
        assert data["ttl"] == 3600
        assert data["max_ttl"] == 7200


class TestServiceAccountCheckout:
    """Test check-out and check-in operations."""

    def test_checkout_verify_and_checkin(self, vault_client, library_set):
        """Check out a service account, verify creds, check status, then check in."""
        # Check out
        resp = vault_client.write(
            f"{MOUNT_POINT}/library/{library_set}/check-out",
            ttl="30m",
        )
        assert resp is not None
        data = resp["data"]
        assert "password" in data
        assert "service_account_name" in data
        account = data["service_account_name"]
        password = data["password"]
        assert account in ["svc-checkout-1", "svc-checkout-2"]
        assert len(password) > 0

        # Verify LDAP bind
        dn = f"cn={account},ou=users,dc=learn,dc=example"
        assert ldap_bind_check(dn, password), \
            f"Checked-out credential should work for LDAP bind on {dn}"

        # Check status — account should be unavailable
        status = vault_client.read(f"{MOUNT_POINT}/library/{library_set}/status")
        assert status["data"][account]["available"] is False

        # Voluntary check-in
        resp = vault_client.write(
            f"{MOUNT_POINT}/library/{library_set}/check-in",
            service_account_names=[account],
        )
        assert account in resp["data"]["check_ins"]

        # Verify available after check-in
        time.sleep(2)
        status = vault_client.read(f"{MOUNT_POINT}/library/{library_set}/status")
        assert status["data"][account]["available"] is True


class TestManagedCheckIn:
    """Test managed (forced) check-in by admin."""

    def test_managed_check_in(self, vault_client, library_set):
        """Admin can force check-in of a service account."""
        resp = vault_client.write(
            f"{MOUNT_POINT}/library/{library_set}/check-out",
            ttl="30m",
        )
        account = resp["data"]["service_account_name"]

        # Force check-in via manage endpoint
        resp = vault_client.write(
            f"{MOUNT_POINT}/library/manage/{library_set}/check-in",
            service_account_names=[account],
        )
        assert resp is not None
        assert account in resp["data"]["check_ins"]

        time.sleep(2)
        status = vault_client.read(f"{MOUNT_POINT}/library/{library_set}/status")
        assert status["data"][account]["available"] is True


class TestCheckOutBothAccounts:
    """Test checking out all available accounts."""

    def test_checkout_both_accounts(self, vault_client, library_set):
        """Check out both service accounts to exhaust the pool."""
        resp1 = vault_client.write(
            f"{MOUNT_POINT}/library/{library_set}/check-out",
            ttl="30m",
        )
        account1 = resp1["data"]["service_account_name"]

        resp2 = vault_client.write(
            f"{MOUNT_POINT}/library/{library_set}/check-out",
            ttl="30m",
        )
        account2 = resp2["data"]["service_account_name"]

        assert account1 != account2, "Should get different accounts"
        assert {account1, account2} == {"svc-checkout-1", "svc-checkout-2"}

        # Both should be unavailable
        status = vault_client.read(f"{MOUNT_POINT}/library/{library_set}/status")
        assert status["data"]["svc-checkout-1"]["available"] is False
        assert status["data"]["svc-checkout-2"]["available"] is False

        # Check both back in
        vault_client.write(
            f"{MOUNT_POINT}/library/manage/{library_set}/check-in",
            service_account_names=[account1, account2],
        )
