# Shared OpenLDAP service account management with Vault namespaces

*A Strategic Guide to Optimizing LDAP Secrets Engine Design in your organisation*

## Challenge

LDAP service accounts are managed centrally, but the users and applications that want to consume those accounts live across many tenant namespaces in HashiCorp Vault. The primary design question then is: Should each tenant namespace run its own LDAP secrets engine configuration, or should LDAP secret engine access be managed centrally and shared safely across namespaces? If you place one LDAP secrets engine mount in every tenant namespace, you duplicate connection configuration, delegated administration, role naming, and ongoing operational ownership for the same backend directory service. That model becomes harder to govern as teams scale and makes it harder to apply a consistent operating model across the organization.

## Solution

The proposed solution keeps LDAP secrets engine management in one shared namespace, while workloads and users continue to authenticate in their own tenant namespaces. The Vault team owns the shared namespace and its management. Users in tenant namespaces consume approved LDAP roles from the shared namespace by using a cross-namespace access mechanism.

This is a targeted solution brief, not a HashiCorp validated pattern. It describes the proposed operating model and technical shape for specific scenarios.

## Proposed architecture

The proposed architecture uses fewer shared LDAP mounts than tenant namespaces.

- Shared namespace:
  - `ns-central`

- Shared LDAP mounts in `ns-central`:
  - `ldap-engineering/`
  - `ldap-sharedservices/`

- Engineering tenant namespaces:
  - `ns-engineering-1`
  - `ns-engineering-2`
  - Both consume `ldap-engineering/`

- Shared-services tenant namespaces:
  - `ns-shared-services-1`
  - `ns-shared-services-2`
  - Both consume `ldap-sharedservices/`

- One OpenLDAP deployment with two naming contexts:
  - `dc=engineering,dc=hashicups,dc=local`
  - `dc=sharedservices,dc=hashicups,dc=local`

Within each naming context, Vault-managed service accounts live under a dedicated Vault-managed OU:

- `ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local`
- `ou=vault,ou=ServiceAccounts,dc=sharedservices,dc=hashicups,dc=local`

Each LDAP mount uses a delegated bind account that lives in a separate admin-style OU:

- `cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local`
- `cn=vault-bind,ou=delegated-admin,dc=sharedservices,dc=hashicups,dc=local`

Those bind accounts should have password change and reset rights only on the corresponding Vault-managed OU, not across the whole directory.

## Architecture diagram

The following diagram summarizes the proposed shared-namespace model.

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 55, 'rankSpacing': 70}} }%%
%% Shared OpenLDAP service account management across Vault namespaces.
%% Solid arrows show the main request path. Dotted arrows show delegated administration boundaries.
flowchart LR
  classDef control fill:#E8F0FE,stroke:#1A73E8,stroke-width:2px,color:#0B1F33;
  classDef shared fill:#E6F4EA,stroke:#137333,stroke-width:3px,color:#0B1F33;
  classDef tenant fill:#FFF4E5,stroke:#B06000,stroke-width:2px,color:#0B1F33;
  classDef ldap fill:#F3E8FD,stroke:#7E57C2,stroke-width:2px,color:#0B1F33;
  classDef actor fill:#FCE8E6,stroke:#D93025,stroke-width:2px,color:#0B1F33;
  classDef note fill:#FFF8C5,stroke:#8D6E00,stroke-width:2px,color:#0B1F33;

  eng1Actor["Engineering apps/users"]
  eng2Actor["Engineering apps/users"]
  svc1Actor["Shared services apps/users"]
  svc2Actor["Shared services apps/users"]
  vaultAdminActor["Vault admins and pipelines"]

  subgraph vault["**Vault Enterprise Cluster**"]
    direction TB
    root["Admin control plane<br/>shared mount configuration"]
    gpamode["**Cross-namespace access**<br/>group_policy_application_mode=any"]
    root --> gpamode


    subgraph engTenants["**Engineering namespaces**"]
      direction LR
      subgraph nsEng1["ns-engineering-1"]
        direction TB
        eng1Auth["Auth methods"]
        eng1Alias["Entity alias"]
        eng1Auth --> eng1Alias
      end
      subgraph nsEng2["ns-engineering-2"]
        direction TB
        eng2Auth["Auth methods"]
        eng2Alias["Entity alias"]
        eng2Auth --> eng2Alias
      end
    end

    subgraph svcTenants["**Shared services namespaces**"]
      direction LR
      subgraph nsSvc1["ns-shared-services-1"]
        direction TB
        svc1Auth["Auth methods"]
        svc1Alias["Entity alias"]
        svc1Auth --> svc1Alias
      end
      subgraph nsSvc2["ns-shared-services-2"]
        direction TB
        svc2Auth["Auth methods"]
        svc2Alias["Entity alias"]
        svc2Auth --> svc2Alias
      end
    end

    subgraph ldapShared["**Shared namespace: ns-central**"]
      direction TB
      engGroup["**Engineering entity group**<br/>policy grants on ldap-engineering/"]
      svcGroup["**Shared services entity group**<br/>policy grants on ldap-sharedservices/"]
      ldapEng["ldap-engineering/"]
      ldapSvc["ldap-sharedservices/"]
      rolePattern["**Hierarchical role pattern**<br/>&lt;namespace&gt;/&lt;team&gt;/&lt;app&gt;/&lt;role-type&gt;/&lt;role-name&gt;"]
      examplePath["**Example static role**<br/>ldap-engineering/static-role/ns-engineering-1/team1/app1/static/svc-account-1"]

      rolePattern -.-> examplePath
      rolePattern -.-> ldapEng
      rolePattern -.-> ldapSvc
      engGroup --> ldapEng
      svcGroup --> ldapSvc
    end
  end

  subgraph openldap["**OpenLDAP deployment**"]
    direction LR
    ldapEndpoint["OpenLDAP endpoint<br/>ldaps://openldap.hashicups.local:636"]

    subgraph engDir["**Engineering directory**<br/>dc=engineering,dc=hashicups,dc=local"]
      direction TB
      engDelegatedOu["cn=vault-bind,ou=delegated-admin"]
      engVaultOu["ou=vault, ou=ServiceAccounts"]
      engDelegatedOu -. "change/reset rights only" .-> engVaultOu
    end

    subgraph svcDir["**Shared services directory**<br/>dc=sharedservices,dc=hashicups,dc=local"]
      direction TB
      svcDelegatedOu["cn=vault-bind,ou=delegated-admin"]
      svcVaultOu["ou=vault, ou=ServiceAccounts"]
      svcDelegatedOu -. "change/reset rights only" .-> svcVaultOu
    end

    ldapEndpoint --> engDir
    ldapEndpoint --> svcDir
  end

  eng1Actor -->|"authenticates to namespace"| eng1Auth
  eng2Actor -->|"authenticates to namespace"| eng2Auth
  svc1Actor -->|"authenticates to namespace"| svc1Auth
  svc2Actor -->|"authenticates to namespace"| svc2Auth
  vaultAdminActor -->|"authenticates to root namespace"| root
  
  gpamode --> ldapShared

  eng1Alias -->|"maps into"| engGroup
  eng2Alias -->|"maps into"| engGroup
  svc1Alias -->|"maps into"| svcGroup
  svc2Alias -->|"maps into"| svcGroup

  ldapSvc -->|"uses shared endpoint"| ldapEndpoint
  ldapEng -->|"uses shared endpoint"| ldapEndpoint

  ldapEng -. "binds as cn=Vault-bind" .-> engDelegatedOu
  ldapSvc -. "binds as cn=Vault-bind" .-> svcDelegatedOu

  class root,gpamode,engGroup,svcGroup,vaultAdminActor control;
  class ldapEng,ldapSvc shared;
  class rolePattern,examplePath note;
  class eng1Auth,eng1Alias,eng2Auth,eng2Alias,svc1Auth,svc1Alias,svc2Auth,svc2Alias tenant;
  class ldapEndpoint,engDelegatedOu,engVaultOu,svcDelegatedOu,svcVaultOu ldap;
  class eng1Actor,eng2Actor,svc1Actor,svc2Actor actor;
```

## Why the shared namespace is the right boundary

The customer already has a centralized operating model for service account management. The same principle should apply inside Vault.

You should place the LDAP secrets engine mounts in `ns-central` because:

- the LDAP connection configuration is shared infrastructure, not tenant-local configuration
- service account lifecycle is centrally owned
- the Vault team can govern mount creation, bind credentials, password policies, and rotation behavior consistently
- tenant consumers can stay isolated at the namespace level without inheriting responsibility for LDAP backend administration

This model also avoids a common design trap. The goal is not “one mount per tenant namespace.” The goal is “one shared mount per centrally managed directory boundary.” That is why multiple engineering namespaces consume `ldap-engineering/`, and multiple shared-services namespaces consume `ldap-sharedservices/`.

## Why two shared mounts communicate the model better than many shared mounts

In this scenario, the important design signal is not namespace count. It is directory ownership and shared administration.

That is why the example uses:

- `ldap-engineering/` for engineering consumer namespaces
- `ldap-sharedservices/` for shared-services consumer namespaces

This keeps the architecture aligned to directory ownership and avoids overfitting the mount layout to the namespace count. If the customer later adds more centrally managed directories, you can add more shared mounts without changing the overall operating pattern.

## How entity aliases in tenant namespaces map to shared access in `ns-central`

The primary cross-namespace mechanism is still `group_policy_application_mode=any`, but the runtime flow is easier to understand when you describe the identity path explicitly.

The request flow can be summarized as follows:

1. An app or user authenticates to the tenant auth method in its own namespace, for example `ns-engineering-1`.
2. That auth flow resolves or creates an entity alias for the caller in the tenant namespace.
3. The entity alias maps to an entity group in `ns-central`.
4. The entity group in `ns-central` carries the shared access policy for the appropriate LDAP mount and role paths.
5. The caller requests credentials from the shared namespace.
6. Because `group_policy_application_mode=any` is enabled, the token issued in the tenant namespace can use the shared group policy when calling the shared LDAP mount.
7. The shared LDAP mount manages the service account in OpenLDAP through the delegated bind account and the Vault-managed OU.

This gives you a clearer story than simply saying that a token “targets `ns-central`.” The important thing is that the tenant-side identity resolves into shared authorization owned in `ns-central`.

## OpenLDAP directory layout and delegated administration

The OpenLDAP layout should make a clear separation between:

- the OU where Vault-managed service accounts live
- the OU where the delegated bind account lives

For engineering:

- Vault-managed accounts:
  - `ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local`
- Delegated bind account location:
  - `cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local`

For shared services:

- Vault-managed accounts:
  - `ou=vault,ou=ServiceAccounts,dc=sharedservices,dc=hashicups,dc=local`
- Delegated bind account location:
  - `cn=vault-bind,ou=delegated-admin,dc=sharedservices,dc=hashicups,dc=local`

This separation matters operationally.

You do not want the bind account to sit alongside the service accounts that Vault is rotating and issuing. You want a clearly distinct administrative identity whose permissions are scoped only to the OU that Vault manages. That gives you a simpler control boundary and a cleaner story for least privilege.

For the LDAP secrets engine configuration itself:

- use `schema="openldap"`
- prefer `ldaps://` or `starttls=true`
- configure each mount to target the right naming context
- scope `userdn` to the Vault-managed OU under `ou=vault,ou=ServiceAccounts,...`
- keep the bind DN delegated and narrowly privileged
- once an LDAP secrets engine mount is configured, perform rotate-root on the binddn so that only Vault knows the password.

## Hierarchical role path convention on the shared mounts

Each shared mount should use hierarchical paths for role names so that one mount can safely serve several tenant namespaces and several teams within those namespaces.

Use a naming pattern like:

```text
<namespace>/<team>/<app>/<role-type>/<role-name>
```

Use these conventions consistently:

- `<namespace>` uses the full namespace name, including the `ns-` prefix
- `<team>` uses generic placeholders such as `team1`, `team2`
- `<app>` uses generic placeholders such as `app1`, `app2`
- `<role-type>` uses:
  - `static`
  - `library`
  - `dynamic`
- `<role-name>` uses:
  - the service account name for `static`
  - the pool or library-set name for `library`
  - the dynamic role name for `dynamic`

This gives you one naming model that works across all role families without creating per-tenant mounts. Additionally, this hierarchical structure allows you to structure granular policies (e.g. per app, per role) or broader policies (e.g. per team, per namespace).

## Compact example table for role paths

The API prefix differs by role family, but the hierarchical name stays consistent. The examples below show concrete paths under the two shared mounts using the same simplified namespace model as the diagram.

| Consumer namespace | Shared mount | Static example | Library example | Dynamic example |
|---|---|---|---|---|
| `ns-engineering-1` | `ldap-engineering/` | `ldap-engineering/static-role/ns-engineering-1/team1/app1/static/svc-account-1` | `ldap-engineering/library/ns-engineering-1/team1/app1/library/pool1` | `ldap-engineering/role/ns-engineering-1/team1/app1/dynamic/dynrole1` |
| `ns-engineering-2` | `ldap-engineering/` | `ldap-engineering/static-role/ns-engineering-2/team2/app2/static/svc-account-2` | `ldap-engineering/library/ns-engineering-2/team2/app2/library/pool1` | `ldap-engineering/role/ns-engineering-2/team2/app2/dynamic/dynrole1` |
| `ns-shared-services-1` | `ldap-sharedservices/` | `ldap-sharedservices/static-role/ns-shared-services-1/team1/app1/static/svc-account-1` | `ldap-sharedservices/library/ns-shared-services-1/team1/app1/library/pool1` | `ldap-sharedservices/role/ns-shared-services-1/team1/app1/dynamic/dynrole1` |
| `ns-shared-services-2` | `ldap-sharedservices/` | `ldap-sharedservices/static-role/ns-shared-services-2/team2/app2/static/svc-account-2` | `ldap-sharedservices/library/ns-shared-services-2/team2/app2/library/pool1` | `ldap-sharedservices/role/ns-shared-services-2/team2/app2/dynamic/dynrole1` |

## One complete example flow

The architecture is easiest to understand when you walk one concrete end-to-end example.

Example engineering flow:

1. An app or user for `ns-engineering-1` authenticates to the tenant auth method in `ns-engineering-1`.
2. Vault creates or resolves an entity alias for that caller in `ns-engineering-1`.
3. That alias maps to an entity group in `ns-central` that carries the engineering shared-access policy.
4. The caller requests service account credentials associated with the engineering mount from the `ns-central` namespace.
5. One direct example role path is:

   ```text
   ldap-engineering/static-role/ns-engineering-1/team1/app1/static/svc-account-1
   ```

6. The corresponding credential read path is:

   ```text
   ldap-engineering/static-cred/ns-engineering-1/team1/app1/static/svc-account-1
   ```

7. `ldap-engineering/` connects to OpenLDAP using:

   ```text
   cn=vault-bind,ou=delegated-admin,dc=engineering,dc=hashicups,dc=local
   ```

8. The mount manages the service account located under:

   ```text
   ou=vault,ou=ServiceAccounts,dc=engineering,dc=hashicups,dc=local
   ```

This example shows the runtime path from tenant authentication through shared authorization to a Vault-managed service account in the engineering directory.

## When to use static, library, and dynamic roles

All three role families are useful in this design.

### Static roles

Use static roles when an integration needs a stable named service account and Vault should rotate its password over time.

This is the best fit for:

- legacy integrations
- middleware platforms with fixed account expectations
- long-lived service account patterns where a stable identity is required

#### Considerations
For existing service accounts, do not move a production account into a Vault managed OU just so Vault can start rotating it as a static role. Moving the object changes its distinguished name and can break scripts, ACL references, application configuration, or other dependencies that the organization may not have fully cataloged yet.

Instead, create a new service account in the Vault-managed OU with the same permissions and scope as the existing account, onboard that new account into Vault rotation, update applications and operational workflows to use the new account, verify the cutover, and then retire the old account safely. _That migration pattern reduces the risk of breaking unknown downstream dependencies while still moving toward centrally managed password rotation._

### Library sets

Use library sets when operators need controlled checkout and return semantics for shared accounts.

This is the best fit for:

- human-operated support workflows
- limited-time privileged access
- pooled operational accounts that should not be shared manually outside Vault

### Dynamic roles

Use dynamic roles when you want short-lived, bounded access patterns and the workload can tolerate ephemeral identities.

This is the best fit for:

- automation jobs
- temporary operational workflows
- time-boxed access where automatic cleanup is desirable

The key point is that all three role families can live under the same shared mount as long as the naming convention stays consistent and access policies stay narrow.

## Ownership and onboarding model

The Vault team owns the shared service boundary.

That means the Vault team owns:

- the `ns-central` namespace
- the shared LDAP mounts
- shared access policies
- tenant configuration management
- onboarding changes through Terraform and CI/CD workflows
- the role naming standard
- the mount-to-directory mapping

In this model, onboarding is not an ad hoc UI exercise. The Vault team manages namespace configuration and shared LDAP access patterns through code and promotion workflows. That keeps the operating model consistent with the customer's centralized service account management approach.

Tenant teams remain consumers of the service. They request onboarding and approved access, but they do not own the shared LDAP backend configuration.

## Risks and considerations

A few operational considerations are worth calling out:

- `group_policy_application_mode=any` is cluster-wide and should be reviewed deliberately
- hierarchical naming only helps if the team enforces it consistently, automation is recommended.
- the delegated bind account must stay narrowly privileged to the Vault-managed OU
- the shared namespace model works only if ownership is explicit and centralized

## Related resources

- [Vault LDAP secrets engine documentation](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP hierarchical paths documentation](https://developer.hashicorp.com/vault/docs/secrets/ldap#hierarchical-paths)
- [Vault namespace structuring guidance](https://developer.hashicorp.com/vault/tutorials/enterprise/namespace-structure)
- [Configure cross-namespace access with group policy application](https://developer.hashicorp.com/vault/docs/enterprise/namespaces/configure-cross-namespace-access)

## Conclusion

This targeted solution keeps the LDAP backend shared and centrally governed, while still letting multiple tenant namespaces consume the service cleanly. The important move is to centralize the LDAP secrets engine mounts from tenant namespaces: many namespaces can consume one shared LDAP mount when the directory boundary, delegated administration model, identity mapping, and hierarchical naming convention are designed well.
