"""
Pytest configuration and shared fixtures for Vault LDAP Secrets Engine tests.
"""
import base64
import os
import subprocess
import time

import hvac
import ldap
import pytest


# ---------------------------------------------------------------------------
# Environment constants
# ---------------------------------------------------------------------------
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_ROOT_TOKEN = os.environ["VAULT_ROOT_TOKEN"]  # must be set in environment

OPENLDAP_CONTAINER = "vault-ldap-openldap"
LDAP_ADMIN_DN = "cn=admin,dc=hashicups,dc=local"
LDAP_ADMIN_PASSWORD = "2LearnVault"
LDAP_SERVICE_ACCOUNTS_DN = "ou=ServiceAccounts,dc=hashicups,dc=local"
LDAP_ENGINEERING_SERVICE_ACCOUNTS_DN = f"ou=engineering,{LDAP_SERVICE_ACCOUNTS_DN}"

MOUNT_POINT = "ldap"
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_ldif_file(filename):
    """Read an LDIF file and return its base64-encoded content."""
    path = os.path.join(PROJECT_DIR, "setup", "ldifs", filename)
    with open(path) as file_handle:
        return base64.b64encode(file_handle.read().encode()).decode()


def _run_openldap_command(*command, input=None, check=False):
    """Run a command inside the OpenLDAP container."""
    docker_exec = ["docker", "exec"]
    if input is not None:
        docker_exec.append("-i")
    docker_exec.extend([OPENLDAP_CONTAINER, *command])
    return subprocess.run(
        docker_exec,
        input=input,
        check=check,
        capture_output=True,
        text=True,
    )


def _run_openldap_ldapi_command(tool, *args, input=None, check=False):
    """Run an ldapi:/// command inside the OpenLDAP container."""
    return _run_openldap_command(
        tool,
        "-Y",
        "EXTERNAL",
        "-H",
        "ldapi:///",
        *args,
        input=input,
        check=check,
    )


# ---------------------------------------------------------------------------
# Helper: get OpenLDAP container IP on the docker bridge network
# ---------------------------------------------------------------------------
def get_openldap_ip():
    result = subprocess.run(
        ["docker", "inspect", OPENLDAP_CONTAINER,
         "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"],
        capture_output=True, text=True
    )
    ip = result.stdout.strip()
    if not ip:
        raise RuntimeError(f"Cannot determine IP of container {OPENLDAP_CONTAINER}")
    return ip


OPENLDAP_IP = get_openldap_ip()
LDAP_URL = f"ldap://{OPENLDAP_IP}"
# For host-side ldap operations we use localhost:389
LDAP_HOST_URL = "ldap://127.0.0.1"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture(scope="session")
def vault_root_client():
    """Vault client authenticated with root token."""
    client = hvac.Client(url=VAULT_ADDR, token=VAULT_ROOT_TOKEN)
    assert client.is_authenticated(), "Root client not authenticated"
    return client


@pytest.fixture(scope="session")
def admin_token(vault_root_client):
    """Create an admin token with ldap-admin policy for the test session."""
    # Ensure policy exists
    policy_path = os.path.join(PROJECT_DIR, "setup", "policies", "admin-policy.hcl")
    with open(policy_path) as f:
        policy_hcl = f.read()
    vault_root_client.sys.create_or_update_policy("ldap-admin", policy_hcl)

    result = vault_root_client.auth.token.create(policies=["ldap-admin"], ttl="8h")
    return result["auth"]["client_token"]


@pytest.fixture(scope="session")
def vault_client(admin_token):
    """Vault client authenticated with admin token."""
    client = hvac.Client(url=VAULT_ADDR, token=admin_token)
    assert client.is_authenticated(), "Admin client not authenticated"
    return client


@pytest.fixture(scope="session")
def ensure_ldap_engine(vault_client):
    """Ensure LDAP secrets engine is enabled and configured."""
    # Check if already mounted
    mounts = vault_client.sys.list_mounted_secrets_engines()
    if f"{MOUNT_POINT}/" not in mounts:
        vault_client.sys.enable_secrets_engine("ldap", path=MOUNT_POINT)
        vault_client.write(
            f"{MOUNT_POINT}/config",
            binddn=LDAP_ADMIN_DN,
            bindpass=LDAP_ADMIN_PASSWORD,
            url=LDAP_URL,
            schema="openldap",
            userdn=LDAP_SERVICE_ACCOUNTS_DN,
            userattr="cn",
        )
    return True


# ---------------------------------------------------------------------------
# LDAP verification helpers
# ---------------------------------------------------------------------------
def ldap_bind_check(dn, password, url=None):
    """Try to bind to LDAP with the given DN and password. Returns True/False."""
    _url = url or LDAP_HOST_URL
    conn = ldap.initialize(_url)
    conn.set_option(ldap.OPT_NETWORK_TIMEOUT, 5)
    try:
        conn.simple_bind_s(dn, password)
        conn.unbind_s()
        return True
    except ldap.INVALID_CREDENTIALS:
        return False
    except Exception:
        return False


def ldap_search(base, search_filter, attrs=None):
    """Search LDAP using docker exec (avoids issues with rotated admin password)."""
    result = _run_openldap_ldapi_command(
        "ldapsearch",
        "-b",
        base,
        search_filter,
        *(attrs or []),
    )
    return result.stdout


def ldap_entry_exists(cn, base=None):
    """Check if an LDAP entry with the given CN exists."""
    _base = base or LDAP_SERVICE_ACCOUNTS_DN
    output = ldap_search(_base, f"(cn={cn})", ["cn"])
    return f"cn: {cn}" in output


def service_account_dn(cn, parent_dn=LDAP_SERVICE_ACCOUNTS_DN):
    """Build the DN for a service account entry under the given parent OU."""
    return f"cn={cn},{parent_dn}"


def _resolve_account_dn(cn, dn=None, parent_dn=LDAP_SERVICE_ACCOUNTS_DN):
    """Resolve an explicit DN or build one from the service account name."""
    if dn:
        return dn
    if cn == "admin":
        return LDAP_ADMIN_DN
    return service_account_dn(cn, parent_dn=parent_dn)


def wait_for_condition(condition_fn, timeout=30, interval=2, msg="Condition"):
    """Poll until condition_fn returns True or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition_fn():
            return True
        time.sleep(interval)
    raise TimeoutError(f"{msg} not met within {timeout}s")


def reset_ldap_account_password(cn, new_password, dn=None, parent_dn=LDAP_SERVICE_ACCOUNTS_DN):
    """Reset an LDAP account password using docker exec.
    For the admin account, the DN is cn=admin,dc=hashicups,dc=local (not under ou=ServiceAccounts).
    """
    target_dn = _resolve_account_dn(cn, dn=dn, parent_dn=parent_dn)

    # Use ldappasswd as the current admin (which Vault controls after rotation)
    # We use docker exec with ldapmodify to reset the password internally
    ldif_content = f"""dn: {target_dn}
changetype: modify
replace: userPassword
userPassword: {new_password}
"""
    _run_openldap_ldapi_command("ldapmodify", input=ldif_content, check=True)


def recreate_service_account(cn, password, dn=None, parent_dn=LDAP_SERVICE_ACCOUNTS_DN):
    """Delete and recreate an LDAP service account using docker exec (SASL EXTERNAL)."""
    dn = _resolve_account_dn(cn, dn=dn, parent_dn=parent_dn)

    # Delete if exists (ignore errors)
    delete_ldif = f"dn: {dn}\nchangetype: delete\n"
    _run_openldap_ldapi_command("ldapmodify", input=delete_ldif)

    # Create service account
    add_ldif = f"""dn: {dn}
objectClass: person
objectClass: top
cn: {cn}
sn: {cn}
userPassword: {password}
"""
    result = _run_openldap_ldapi_command("ldapadd", input=add_ldif)
    if result.returncode != 0 and "Already exists" not in result.stderr:
        # If it already exists, reset the password instead
        if "already exists" in result.stderr.lower():
            reset_ldap_account_password(cn, password, dn=dn)
        else:
            raise RuntimeError(f"Failed to create LDAP service account {cn}: {result.stderr}")
