# Test Suite Details

This directory contains the automated validation for the Vault LDAP Secrets Engine demo.

See the root [README](../README.md) for environment setup, demo usage, and architecture. This file keeps the detailed per-file test breakdown close to the tests themselves.

**41 tests** across 7 files, organized by feature area. All tests use `pytest` with the `hvac` Python client and verify results against both the Vault API and the live OpenLDAP directory.

## `test_01_setup.py` — Engine Setup & Root Rotation (6 tests)

| Test | What It Verifies |
|---|---|
| `test_engine_is_enabled` | LDAP engine is mounted at `ldap/` |
| `test_config_is_readable` | Engine config returns expected `binddn` and `schema` |
| `test_manual_root_rotation` | `POST ldap/rotate-root` succeeds, engine remains functional |
| `test_config_still_works_after_rotation` | Static role creation works after root rotation |
| `test_scheduled_root_rotation_enterprise` | Enterprise: `rotation_schedule` cron expression accepted |
| `test_disable_automated_rotation_enterprise` | Enterprise: `disable_automated_rotation` toggle works |

## `test_03_static_roles.py` — Static Roles (12 tests)

| Test | What It Verifies |
|---|---|
| `test_create_static_role` | Create role for seeded service account `svc-account-1` with 1h rotation |
| `test_read_static_credentials` | `GET ldap/static-cred/svc-account-1` returns username + password |
| `test_static_credential_works_in_ldap` | LDAP bind succeeds with Vault-managed password |
| `test_list_static_roles` | Role appears in `LIST ldap/static-role` |
| `test_create_second_static_role` | Create a second role for `svc-account-2` |
| `test_delete_static_role` | Delete role, confirm removal from list |
| `test_manual_rotation` | `POST ldap/rotate-role/svc-account-1` changes the password |
| `test_last_password_field` | `last_password` is populated after rotation |
| `test_auto_rotation_short_period` | 10s `rotation_period` triggers automatic rotation |
| `test_nested_service_account_static_role_rotation` | Static role for `svc-account-3` under `ou=engineering,ou=ServiceAccounts,...` can be created, read, and rotated while `userdn` stays at `ou=ServiceAccounts,...` |
| `test_skip_import_rotation` | `skip_import_rotation=true` prevents initial password change |
| `test_cleanup_primary_static_role` | Cleanup for downstream tests |

## `test_04_dynamic_creds.py` — Dynamic Credentials (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_dynamic_role` | Create role with base64-encoded LDIF templates |
| `test_list_dynamic_roles` | Role appears in `LIST ldap/role` |
| `test_read_dynamic_role` | Read role returns creation/deletion LDIF templates |
| `test_generate_and_verify_dynamic_credentials` | Generate creds → LDAP bind succeeds → revoke → LDAP entry deleted |
| `test_default_ttl` | Lease TTL matches configured `default_ttl` |
| `test_custom_username_template` | `username_template` with Go template produces expected format |

## `test_05_library.py` — Service Account Library (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_library_set` | Create library set with 2 service accounts |
| `test_list_library_sets` | Library set appears in `LIST ldap/library` |
| `test_read_library_set` | Read returns correct accounts and `max_ttl` |
| `test_checkout_verify_and_checkin` | Check-out → LDAP bind → check-in cycle |
| `test_managed_check_in` | Force check-in of another client's checked-out account |
| `test_checkout_both_accounts` | Both pool accounts checked out → 3rd request blocked |

## `test_06_hierarchical.py` — Hierarchical Paths (5 tests)

| Test | What It Verifies |
|---|---|
| `test_list_top_level_roles` | `LIST ldap/static-role` shows `org/` prefix |
| `test_list_org_level_roles` | `LIST ldap/static-role/org/` shows `dev` and `platform/` |
| `test_list_platform_level_roles` | `LIST ldap/static-role/org/platform/` shows `sre` |
| `test_read_hierarchical_role` | Read `ldap/static-role/org/dev` returns role details |
| `test_read_hierarchical_credentials` | Read `ldap/static-cred/org/dev` returns valid credentials |

## `test_07_password_policy.py` — Password Policies (6 tests)

| Test | What It Verifies |
|---|---|
| `test_create_password_policy` | Create policy with length + charset rules |
| `test_apply_policy_to_engine` | Set `password_policy` on LDAP engine config |
| `test_generate_password_with_policy` | `GET sys/policies/password/<name>/generate` returns compliant password |
| `test_static_role_respects_policy` | Static role rotation produces policy-compliant passwords |
| `test_dynamic_role_respects_policy` | Dynamic credential passwords follow the policy |
| `test_remove_password_policy_from_engine` | Clear policy from engine config (cleanup) |
