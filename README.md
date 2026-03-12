# Vault LDAP Secrets Engine — Full Feature Demo

A comprehensive demonstration of **every feature** of HashiCorp Vault's [LDAP Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/ldap), built for customer presentations and SE enablement. Uses OpenLDAP in Docker alongside an existing Vault Enterprise cluster.

---

## Features Demonstrated

| # | Feature Area | What's Covered |
|---|---|---|
| 1 | **Engine Setup & Configuration** | Enable engine, configure OpenLDAP connection, verify config |
| 2 | **Root Credential Rotation** | Manual rotation, scheduled rotation (Enterprise), disable/re-enable auto-rotation |
| 3 | **Static Roles** | CRUD operations, credential read, LDAP bind verification, manual rotation, auto-rotation with `rotation_period`, `skip_import_rotation` |
| 4 | **Dynamic Credentials** | LDIF-based role creation, credential generation, lease revocation with LDAP cleanup, custom `username_template`, TTL configuration |
| 5 | **Service Account Library** | Library set CRUD, check-out/check-in, managed (forced) check-in, pool exhaustion behavior |
| 6 | **Hierarchical Paths** | Multi-level role organization (`org/dev`, `org/platform/sre`), listing at each level |
| 7 | **Custom Password Policies** | Policy creation, engine-level application, verification against static and dynamic roles |

---

## Project Structure

```
vault-ldap-se/
├── demo.sh                              # Interactive customer demo script
├── run_tests.sh                         # Pytest runner with state reset
├── cleanup.sh                           # Tear down all resources
├── requirements.txt                     # Python dependencies
├── setup/
│   ├── 00_openldap_setup.sh             # OpenLDAP Docker container + data
│   ├── 01_vault_policy_setup.sh         # Vault admin policy & token
│   ├── 02_ldap_engine_config.sh         # Enable & configure LDAP engine
│   ├── ldifs/
│   │   ├── base.ldif                    # Base OUs (users, groups)
│   │   ├── users.ldif                   # alice, bob + dev/ops groups
│   │   ├── service_accounts.ldif        # svc-checkout-1, svc-checkout-2
│   │   ├── creation.ldif               # Dynamic role creation template
│   │   ├── deletion.ldif               # Dynamic role deletion template
│   │   └── rollback.ldif               # Dynamic role rollback template
│   └── policies/
│       └── admin-policy.hcl             # Vault policy for demo operations
└── tests/
    ├── conftest.py                      # Fixtures, LDAP helpers, constants
    ├── test_01_setup.py                 # Engine setup & root rotation
    ├── test_03_static_roles.py          # Static role lifecycle
    ├── test_04_dynamic_creds.py         # Dynamic credentials
    ├── test_05_library.py               # Service account check-out
    ├── test_06_hierarchical.py          # Hierarchical path organization
    └── test_07_password_policy.py       # Custom password policies
│       └── admin-policy.hcl             # Vault policy for demo operations
└── assets/
    ├── vault-ldap-se-demo-recording.webM # Fixtures, LDAP helpers, constants
```

---

## Prerequisites

| Component | Version | Notes |
|---|---|---|
| Vault Enterprise | v1.21+ | Running in Docker (container: `vault-ent`) |
| Docker | Any recent | For OpenLDAP container |
| Python | 3.9+ | For pytest test suite |
| Vault CLI | v1.21+ | For demo script |

---

## Quick Start

### 1. Set environment variables

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<your-root-token>"          # Root or admin token
export VAULT_ROOT_TOKEN="<your-root-token>"     # Used by test runner
```

### 2. Install Python dependencies

```bash
pip3 install -r requirements.txt
```

### 3. Run the interactive demo (recommended for customers)

```bash
./demo.sh                    # Interactive — pauses between each section
```
#### Video recording of the demo
<video src="https://github.com/user-attachments/assets/0f3b4990-15e6-4f72-bf2d-e41cabb74a90" controls="controls" style="max-width: 100%;">
</video>
### 4. Or run the automated test suite

```bash
# Full setup + tests (from scratch)
bash setup/00_openldap_setup.sh
bash setup/01_vault_policy_setup.sh
bash setup/02_ldap_engine_config.sh
./run_tests.sh

# Just re-run tests (infrastructure already up)
./run_tests.sh
```

---

## Demo Script Usage

The demo script (`demo.sh`) walks through all 7 feature areas with colored output, command display, and optional pause-between-steps for live narration.

```bash
./demo.sh                        # Interactive (pauses for presenter)
./demo.sh --auto                 # Non-interactive (runs straight through)
./demo.sh --skip-setup           # Skip infrastructure setup (reuse existing)
./demo.sh --no-cleanup           # Keep all resources after demo
./demo.sh --auto --no-cleanup    # Quick validation run
```

**Flags:**

| Flag | Effect |
|---|---|
| `--auto` | Disables pause prompts — runs all sections continuously |
| `--skip-setup` | Skips Section 0 (OpenLDAP container creation, LDAP population, engine configuration). Assumes infrastructure is already running. |
| `--no-cleanup` | Preserves all resources (containers, roles, engine) after the demo finishes. Useful for post-demo exploration. |

**Output**: Each section shows the Vault/LDAP commands being executed, their output, and a pass/fail summary table at the end.

---

## Test Suite Details

**40 tests** across 7 files, organized by feature area. All tests use `pytest` with the `hvac` Python client and verify results against both the Vault API and the live OpenLDAP directory.

### test_01_setup.py — Engine Setup & Root Rotation (6 tests)

| Test | What It Verifies |
|---|---|
| `test_engine_is_enabled` | LDAP engine is mounted at `ldap/` |
| `test_config_is_readable` | Engine config returns expected `binddn` and `schema` |
| `test_manual_root_rotation` | `POST ldap/rotate-root` succeeds, engine remains functional |
| `test_config_still_works_after_rotation` | Static role creation works after root rotation |
| `test_scheduled_root_rotation_enterprise` | Enterprise: `rotation_schedule` cron expression accepted |
| `test_disable_automated_rotation_enterprise` | Enterprise: `disable_automated_rotation` toggle works |

### test_03_static_roles.py — Static Roles (11 tests)

| Test | What It Verifies |
|---|---|
| `test_create_static_role` | Create role for user `alice` with 1h rotation |
| `test_read_static_credentials` | `GET ldap/static-cred/alice` returns username + password |
| `test_static_credential_works_in_ldap` | LDAP bind succeeds with Vault-managed password |
| `test_list_static_roles` | Role appears in `LIST ldap/static-role` |
| `test_create_second_static_role` | Create a second role for `bob` |
| `test_delete_static_role` | Delete role, confirm removal from list |
| `test_manual_rotation` | `POST ldap/rotate-role/alice` changes the password |
| `test_last_password_field` | `last_password` is populated after rotation |
| `test_auto_rotation_short_period` | 10s `rotation_period` triggers automatic rotation |
| `test_skip_import_rotation` | `skip_import_rotation=true` prevents initial password change |
| `test_cleanup_alice_role` | Cleanup for downstream tests |

### test_04_dynamic_creds.py — Dynamic Credentials (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_dynamic_role` | Create role with base64-encoded LDIF templates |
| `test_list_dynamic_roles` | Role appears in `LIST ldap/role` |
| `test_read_dynamic_role` | Read role returns creation/deletion LDIF templates |
| `test_generate_and_verify_dynamic_credentials` | Generate creds → LDAP bind succeeds → revoke → LDAP entry deleted |
| `test_default_ttl` | Lease TTL matches configured `default_ttl` |
| `test_custom_username_template` | `username_template` with Go template produces expected format |

### test_05_library.py — Service Account Library (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_library_set` | Create library set with 2 service accounts |
| `test_list_library_sets` | Library set appears in `LIST ldap/library` |
| `test_read_library_set` | Read returns correct accounts and `max_ttl` |
| `test_checkout_verify_and_checkin` | Check-out → LDAP bind → check-in cycle |
| `test_managed_check_in` | Force check-in of another client's checked-out account |
| `test_checkout_both_accounts` | Both pool accounts checked out → 3rd request blocked |

### test_06_hierarchical.py — Hierarchical Paths (5 tests)

| Test | What It Verifies |
|---|---|
| `test_list_top_level_roles` | `LIST ldap/static-role` shows `org/` prefix |
| `test_list_org_level_roles` | `LIST ldap/static-role/org/` shows `dev` and `platform/` |
| `test_list_platform_level_roles` | `LIST ldap/static-role/org/platform/` shows `sre` |
| `test_read_hierarchical_role` | Read `ldap/static-role/org/dev` returns role details |
| `test_read_hierarchical_credentials` | Read `ldap/static-cred/org/dev` returns valid credentials |

### test_07_password_policy.py — Password Policies (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_password_policy` | Create policy with length + charset rules |
| `test_apply_policy_to_engine` | Set `password_policy` on LDAP engine config |
| `test_generate_password_with_policy` | `GET sys/policies/password/<name>/generate` returns compliant password |
| `test_static_role_respects_policy` | Static role rotation produces policy-compliant passwords |
| `test_dynamic_role_respects_policy` | Dynamic credential passwords follow the policy |
| `test_remove_password_policy_from_engine` | Clear policy from engine config (cleanup) |

---

## Architecture

```
┌──────────────────────┐         ┌──────────────────────────┐
│   Your Machine       │         │   Docker Bridge Network  │
│                      │         │                          │
│  pytest / demo.sh    │────────▶│  vault-ent (Vault Ent.)  │
│                      │  :8200  │  ┌──────────────────────┐│
│  LDAP bind verify    │────────▶│  │ LDAP Secrets Engine  ││
│                      │  :389   │  └──────┬───────────────┘│
│                      │         │         │                │
│                      │         │         ▼                │
│                      │         │  vault-ldap-openldap     │
│                      │         │  (osixia/openldap:1.4.0) │
│                      │         │  dc=learn,dc=example     │
│                      │         └──────────────────────────┘
└──────────────────────┘
```

- **Vault** connects to OpenLDAP via Docker bridge IP (e.g., `172.17.0.3:389`)
- **Tests/demo** connect to Vault via `localhost:8200` and verify LDAP binds via `localhost:389`
- After root rotation, all LDAP admin operations use **SASL EXTERNAL** (`docker exec ... -Y EXTERNAL -H ldapi:///`) to avoid dependency on knowing the rotated password

---

## LDAP Directory Layout

```
dc=learn,dc=example
├── ou=users
│   ├── cn=alice          (member of: dev)
│   ├── cn=bob            (member of: ops)
│   ├── cn=svc-checkout-1 (library service account)
│   └── cn=svc-checkout-2 (library service account)
└── ou=groups
    ├── cn=dev            (member: alice)
    └── cn=ops            (member: bob)
```

Dynamic credentials are created under `ou=users` and cleaned up on lease revocation via the deletion LDIF template.

---

## Technical Notes

### OpenLDAP rootDN Password Behavior

The `cn=admin,dc=learn,dc=example` is OpenLDAP's **rootDN**. Its authentication password is stored as `olcRootPW` in the config database (`cn=config`), **not** as `userPassword` on the entry itself. Vault's `rotate-root` modifies `userPassword`, which does not affect rootDN authentication. This is expected OpenLDAP behavior — for production, use a non-rootDN service account as the bind DN.

### SASL EXTERNAL Authentication

After root rotation, the original admin password may still work for rootDN (see above). To avoid ambiguity, all administrative LDAP operations in the test suite use SASL EXTERNAL authentication via:

```bash
docker exec vault-ldap-openldap ldapmodify -Y EXTERNAL -H ldapi:///
```

This authenticates via Unix socket credentials (root inside the container) and requires no password.

### Dynamic Credential LDIF Templates

Dynamic roles use Go template syntax in base64-encoded LDIF:

```ldif
# creation.ldif
dn: cn={{.Username}},ou=users,dc=learn,dc=example
objectClass: inetOrgPerson
cn: {{.Username}}
sn: {{.Username}}
userPassword: {{.Password}}
```

Vault processes the templates at credential generation time, creating real LDAP entries. On lease revocation, the deletion template removes the entry.

### Vault Policy Requirements

The `sys/mounts` path (exact) must be included separately from `sys/mounts/*` (wildcard). The wildcard does **not** match the exact path — both are needed for listing mounted engines and managing specific mounts.

---

## Cleanup

```bash
./cleanup.sh
```

This removes:
- OpenLDAP Docker container (`vault-ldap-openldap`)
- LDAP secrets engine (`ldap/`)
- Vault policies (`ldap-admin`)
- Password policies created during the demo

---

## References

- [LDAP Secrets Engine Documentation](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ldap)
- [Tutorial: Static Password Rotation with OpenLDAP](https://developer.hashicorp.com/vault/tutorials/secrets-management/openldap)
