# Mount secrets engines
path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Configure the ldap secrets engine and create roles
path "ldap/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Write ACL policies
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage tokens for verification
path "auth/token/create" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Read password policies
path "sys/policies/password/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Generate passwords from policies
path "sys/policies/password/+/generate" {
  capabilities = ["read"]
}

# Manage leases (for revoking dynamic creds)
path "sys/leases/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
