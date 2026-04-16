# Copilot instructions

## Commands

- Install Python dependencies with `pip3 install -r requirements.txt`.
- There is no dedicated build or lint command in this repository; the executable surfaces are the Bash demo/setup scripts and the pytest suite.
- The full automated test suite runs through `./run_tests.sh`. It resets LDAP and Vault state, then delegates to `python3 -m pytest tests/ -v "$@"`.
- Run a single test file with `./run_tests.sh tests/test_04_dynamic_creds.py -v`.
- Run a single test with `./run_tests.sh tests/test_04_dynamic_creds.py::TestCustomUsernameTemplate::test_custom_username_template -v`.
- Bring up the demo environment from scratch with:

```bash
bash setup/00_openldap_setup.sh
export VAULT_ROOT_TOKEN="<root token>"
bash setup/01_vault_policy_setup.sh
export VAULT_TOKEN="<ldap-admin token printed by the previous script>"
bash setup/02_ldap_engine_config.sh
```

- Run the full feature demo with `./demo.sh`, `./demo.sh --auto`, or `./demo.sh --skip-setup`.
- Run the focused cross-namespace demo with `bash setup/00_openldap_setup.sh` followed by `./demo_service_account_management.sh`.
- Clean up with `./cleanup.sh` for the full demo/test track or `./cleanup_service_account_management.sh` for the focused namespace demo.

## High-level architecture

- This repository is primarily a Bash orchestration layer around an existing Vault Enterprise container named `vault-ent`. The scripts start an OpenLDAP container named `vault-ldap-openldap` on the same Docker network, seed LDAP entries from `setup/ldifs/*.ldif`, and configure Vault's LDAP **secrets engine** rather than Vault's LDAP auth method.
- The main demo/test track is `setup/00_openldap_setup.sh` -> `setup/01_vault_policy_setup.sh` -> `setup/02_ldap_engine_config.sh` -> `demo.sh` / `run_tests.sh`. In that track, Vault mounts the engine at `ldap/`, manages static roles, dynamic roles, service-account library sets, hierarchical paths, and password policies, and the tests verify both Vault API responses and the live LDAP directory.
- The Python test suite (`tests/` + `tests/conftest.py`) uses `hvac` for Vault API calls and also performs direct LDAP verification. Host-side checks bind to `ldap://127.0.0.1`, while administrative LDAP reads and writes run inside the container with `docker exec ... ldapsearch|ldapmodify -Y EXTERNAL -H ldapi:///`.
- `demo_service_account_management.sh` is a separate, narrower demo track. It reuses the same OpenLDAP container but adds a Vault Enterprise namespace topology: `ns-central` hosts a shared LDAP mount (`ldap-engineering/`), `ns-engineering-1` hosts the tenant auth path, and an identity group in `ns-central` grants a tenant token cross-namespace access to a hierarchical static role.
- `perf-replication/` is a separate benchmarking area and is not part of the normal demo or pytest flow.

## Key conventions

- Run the numbered setup scripts in order. `00_openldap_setup.sh` assumes `vault-ent` already exists and joins OpenLDAP to that container's Docker network.
- Demo scripts expect `VAULT_TOKEN`; the pytest flow expects `VAULT_ROOT_TOKEN`. The service-account-management scripts explicitly `unset VAULT_NAMESPACE` before cluster-scoped operations, then set `VAULT_NAMESPACE` per command when working inside `ns-central` or `ns-engineering-1`.
- Static role names are path-like, not flat identifiers. The repo relies on hierarchical role paths such as `org/dev`, `org/platform/sre`, and `ns-engineering-1/team1/app1/static/svc-app1`, so `vault list` and policy paths often target intermediate path segments rather than single role names.
- Dynamic role definitions are sourced from LDIF templates in `setup/ldifs/` and must be base64-encoded before writing them to Vault. The tests and `demo.sh` both follow that pattern for `creation.ldif`, `deletion.ldif`, and `rollback.ldif`.
- Keep `userdn`/search base and managed entry DN distinct. The main LDAP engine config uses `userdn="ou=ServiceAccounts,dc=hashicups,dc=local"`, but static roles may point to nested DNs below that subtree, such as the engineering child OU.
- The cross-namespace demo is stateful at the cluster level: it switches `sys/config/group-policy-application` to `group_policy_application_mode=any` and the cleanup script restores the prior mode when that demo changed it.
- When scripts or tests need to mutate LDAP after root rotation, preserve the existing `docker exec ... -Y EXTERNAL -H ldapi:///` pattern instead of switching to password-based admin operations. This repo depends on SASL EXTERNAL to avoid ambiguity around OpenLDAP rootDN password behavior after Vault rotates `userPassword`.
- Preserve the cleanup pattern in `cleanup.sh`: revoke `ldap/*` leases before disabling the mount so cleanup still succeeds when dynamic or library leases are outstanding.
- `setup/policies/admin-policy.hcl` intentionally grants both `sys/mounts` and `sys/mounts/*`; both paths are needed in this repository's Vault flows.
- The optional phpLDAPadmin flow uses the dedicated read-only `ldapviewer` account. Do not repurpose the LDAP admin account for browser-based inspection because Vault rotates that password during the demo.
