# Service Account Management Design Demo

This repository now includes a second demo track focused on the high-level design described in [`designs/service-account-management-solution-with-hashicorp-vault.md`](./designs/service-account-management-solution-with-hashicorp-vault.md).

Unlike `demo.sh`, this flow is **not** a full feature tour of the LDAP secrets engine. It is a focused Vault Enterprise demo that proves one key design idea:

- a tenant namespace authenticates locally
- `ns-central` hosts the shared LDAP mount
- an identity group in `ns-central` grants access
- the tenant token reads a static credential across namespaces

## Scope

The demo intentionally keeps the topology small:

- one shared namespace: `ns-central`
- one tenant namespace: `ns-engineering-1`
- one shared LDAP mount: `ldap-engineering/`
- one hierarchical static role:
  `ns-engineering-1/team1/app1/static/svc-app1`

Out of scope for this focused demo:

- dynamic LDAP roles
- service account library / check-out flows
- multiple business units or multiple shared mounts

## Prerequisites

- Vault Enterprise is already running and reachable from your workstation
- a Vault token with enough privileges to:
  - create namespaces
  - configure identity entities, aliases, and groups
  - enable and configure secrets engines
  - update `sys/config/group-policy-application`
- the existing OpenLDAP container from this repository is running:

```bash
bash setup/00_openldap_setup.sh
```

Set your Vault environment before running the demo:

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<token-with-enterprise-admin-capabilities>"
```

## Files added for this demo

```text
demo_service_account_management.sh
cleanup_service_account_management.sh
setup/03_service_account_management_openldap.sh
setup/04_service_account_management_vault.sh
setup/service_account_management/engineering_branch.ldif
```

## Quick start

```bash
# Ensure the shared OpenLDAP container exists
bash setup/00_openldap_setup.sh

# Run the focused cross-namespace design demo
./demo_service_account_management.sh
```

To keep the namespaces and LDAP branch around for manual exploration:

```bash
./demo_service_account_management.sh --no-cleanup
```

To clean up afterward:

```bash
./cleanup_service_account_management.sh
```

## What the demo does

1. Extends the existing OpenLDAP container with a dedicated branch under:
   `dc=engineering,dc=hashicups,dc=local`
2. Seeds:
   - a delegated bind DN under `ou=delegated-admin`
   - a Vault-managed OU under `ou=vault,ou=ServiceAccounts`
   - a static service account `svc-app1`
3. Enables cross-namespace identity group policy application with:
   `group_policy_application_mode=any`
4. Creates:
   - `ns-central`
   - `ns-engineering-1`
   - a shared LDAP mount `ldap-engineering/` in `ns-central`
   - a tenant userpass login, entity, alias, and a shared group policy bridge
5. Logs into `ns-engineering-1`, then uses that tenant token to read:
   `ldap-engineering/static-cred/ns-engineering-1/team1/app1/static/svc-app1`
   from `ns-central`

## Script flags

```bash
./demo_service_account_management.sh --help
./demo_service_account_management.sh --auto
./demo_service_account_management.sh --skip-setup
./demo_service_account_management.sh --no-cleanup
```

## Notes

- The demo reuses the existing OpenLDAP container so it does not create a second directory service.
- Cleanup removes the demo namespace resources and the dedicated LDAP branch, but it does not rewrite global OpenLDAP ACL ordering. The delegated-bind ACL entries are additive and remain narrowly scoped to the removed branch.
- If your Vault cluster already uses a non-default group policy mode, the demo restores the original value when it performs its own cleanup in the same run.
