# Vault LDAP secrets engine: `binddn` account permissions

## Overview

This document explains what directory permissions Vault needs when the LDAP secrets engine is configured with a privileged `binddn` account, and how those requirements differ between **OpenLDAP** and **Active Directory**.

The main body focuses on the **root-managed** features most relevant to a customer running **Vault < 1.21.x**:

- `rotate-root`
- root-managed static roles
- service account library
- dynamic roles

**Self-managed static roles** are covered separately at the end because they do not use the privileged `binddn` in the same way.

## Executive summary

### OpenLDAP

- Use a **dedicated service account** as `binddn`, not the OpenLDAP `rootDN`.
- Scope permissions to the **managed subtree or subtrees** only.
- For `rotate-root`, Vault needs to modify `userPassword` on the `binddn` entry.
- For root-managed static roles and the service account library, Vault needs to modify `userPassword` on the managed accounts.
- Only grant add, delete, and broader attribute-write permissions if you actually use **dynamic roles**.
- If dynamic LDIFs touch other objects, such as groups or alternate containers, delegate rights only on those specific objects.

### Active Directory

- Use a **dedicated AD service account** for Vault.
- Use **LDAPS** or **StartTLS**. AD password operations on `unicodePwd` require a protected connection.
- Delegate rights only on the **managed OU or OUs**, or on the specific objects Vault controls.
- For `rotate-root`, allow the Vault AD service account to change or reset its own password.
- For root-managed static roles and the service account library, delegate **Reset Password** on the managed service accounts.
- Only delegate **Create/Delete User** and additional attribute writes if you actually use **dynamic roles**.
- Only delegate **`userAccountControl`** or group-management rights when your LDIF templates or operating model actually need them.

## rotate-root

### OpenLDAP

- Vault writes `userPassword` on the `binddn` entry.
- The `binddn` therefore needs permission to modify `userPassword` on its own entry.
- Do **not** use OpenLDAP `rootDN` as the customer model for this. Vault rotates `userPassword`, but `rootDN` authentication is controlled by `olcRootPW` in `cn=config`, so `rotate-root` can be misleading when `rootDN` is used.

### Active Directory

- Vault rotates the AD service account password through the directory.
- Allow the Vault AD service account to change or reset its own password.

## Static roles and service account library

### OpenLDAP

- These features rotate passwords on existing directory accounts.
- The `binddn` needs permission to modify `userPassword` on every managed account that Vault may rotate.
- `skip_import_rotation` only skips the first rotation during import. It does **not** remove the need for ongoing `userPassword` write access.

### Active Directory

- These features require Vault to reset the passwords of managed directory accounts.
- Delegate **Reset Password** on the managed accounts, or on the OU that contains them.
- If your rotation process also enables, disables, unlocks, or otherwise changes account state, add the matching attribute rights for those same objects.

## Dynamic roles

### OpenLDAP

- Dynamic roles are LDIF-driven. The `binddn` needs permission for every operation in the LDIFs used for create, revoke, and rollback.
- In the common case, that means adding entries in the target OU, deleting entries when revocation or rollback deletes them, and modifying each attribute written by the LDIFs.
- In OpenLDAP ACL terms, create and delete usually also require write access to the parent container's `children` pseudo-attribute and the target entry's `entry` pseudo-attribute.
- If your revocation flow disables or moves accounts instead of deleting them, delegate those modify rights instead of delete rights.

### Active Directory

- Dynamic roles require delegated rights that match the user creation and cleanup template.
- In the common case, that means creating and deleting user objects in the target OU and writing each attribute used by the template, such as `unicodePwd`, `sAMAccountName`, `userPrincipalName`, `cn`, `sn`, `givenName`, and `userAccountControl` when used.
- If revocation disables or moves the account instead of deleting it, delegate those modify rights instead of delete rights.

## Self-managed static roles (Vault 2.0+)

[Self-managed static roles](https://developer.hashicorp.com/vault/docs/secrets/ldap#static-roles) were introduced as a different operating model from the traditional privileged `binddn` approach.
- In a **root-managed** mount, Vault binds with the configured `binddn` and resets passwords on other directory accounts.
- In a **self-managed** mount, Vault binds as the managed account itself and performs that account's own password change.
- The key permission requirement therefore shifts from delegated administrator rights on many objects to each managed account being allowed to change its own password.
- If you run both root-managed and self-managed mounts, keep those permission models separate when designing the directory delegation.

## Permission matrix by feature

| Feature | OpenLDAP | Active Directory |
| --- | --- | --- |
| Root credential rotation | `binddn` must be able to update its own `userPassword` | `binddn` must be able to update its own `unicodePwd` over a secure connection |
| Root-managed static roles | `binddn` must be able to find target accounts and update `userPassword` | `binddn` must be able to find target accounts and reset `unicodePwd` over a secure connection |
| Service account library | Same as root-managed static roles; check-in / expiry rotate passwords | Same as root-managed static roles; check-in / expiry rotate passwords |
| Dynamic roles | `binddn` must be able to perform every LDIF Add / Modify / Delete plus attribute writes in the templates | `binddn` must be able to perform every LDIF Add / Modify / Delete plus attribute writes in the templates; password updates must be secure |
| Self-managed static roles | No privileged `binddn` needed for rotation path | No privileged `binddn` needed for rotation path |
| Automated rotation | No extra directory rights beyond the matching manual feature | No extra directory rights beyond the matching manual feature |