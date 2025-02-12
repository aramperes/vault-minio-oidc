locals {
  users = {
    user1 = {
      vault_password = "changeme"
      minio_policies = ["readonly"]
    }
    user2 = {
      vault_password = "changeme"
      minio_policies = ["readwrite"]
    }
  }
}

// First, we need some sort of authentication backend to authenticate users.
// We will use the userpass backend for this example.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  tune {
    // When the user logs into Vault, the Vault token will be valid for 1 hour (they can request up to 24).
    default_lease_ttl = "1h"
    max_lease_ttl     = "24h"
  }
}

// Register the users in the userpass backend with their respective username and password.
resource "vault_generic_endpoint" "user" {
  for_each   = local.users
  depends_on = [vault_auth_backend.userpass]

  path                 = "auth/userpass/users/${each.key}"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = each.value.vault_password
  })
}

// Creates an entity to represent the user in Vault. The entity has a list of MinIO policies attached to it in the metadata.
// An entity can have multiple aliases (authentication methods).
resource "vault_identity_entity" "user" {
  for_each = local.users
  name     = each.key

  external_policies = true
  metadata = {
    minio_policies = join(",", each.value.minio_policies)
  }
}

// Tie the userpass credentials to their entitiy.
resource "vault_identity_entity_alias" "userpass" {
  for_each = local.users
  name     = each.key

  mount_accessor = vault_auth_backend.userpass.accessor
  canonical_id   = vault_identity_entity.user[each.key].id
}

// Next, we create an "assigmment" which is used to determine which entities are allowed to access a particular client (MinIO).
// We could use groups, but here we just list the users (entities) directly.
resource "vault_identity_oidc_assignment" "minio_users" {
  name = "minio_users"
  entity_ids = [
    for key, val in local.users : vault_identity_entity.user[key].id
  ]
  group_ids = []
}

// Create a signing key. This key will be used to sign JWTs for the OIDC client and also for the MinIO STS role.
resource "vault_identity_oidc_key" "minio" {
  name      = "minio"
  algorithm = "RS256"
  // The root key (for OIDC and STS) is rotated every 24 hours
  rotation_period  = 86400
  verification_ttl = 86400
}

// We create the OIDC client for MinIO. This client will be used by MinIO to authenticate users.
// A client ID and client secret will be returned to be pasted into the MinIO configuration.
resource "vault_identity_oidc_client" "minio" {
  name = "minio"
  key  = vault_identity_oidc_key.minio.name
  redirect_uris = [
    "http://localhost:9001/oauth_callback"
  ]
  assignments = [
    vault_identity_oidc_assignment.minio_users.name
  ]
  // Tokens issued through this client are valid for 1 hour.
  id_token_ttl     = 3600
  access_token_ttl = 3600
}

// Allow the MinIO client to use the signing key.
resource "vault_identity_oidc_key_allowed_client_id" "minio" {
  key_name          = vault_identity_oidc_key.minio.name
  allowed_client_id = vault_identity_oidc_client.minio.client_id
}

// Create a scope for the MinIO policy. When this scope is used, the MinIO policies on the entity will be returned in a claim called "policy".
resource "vault_identity_oidc_scope" "minio_policy" {
  name        = "minio_policy"
  template    = <<EOT
  {
    "policy": {{identity.entity.metadata.minio_policies}}
  }
  EOT
  description = "MinIO policy scope"
}

// In order to allow issuing manual tokens (for STS), we need to create a role for the MinIO client.
// For MinIO to accept the tokens, it must have the same client_id as the client application.
resource "vault_identity_oidc_role" "minio_sts" {
  name      = "minio"
  key       = vault_identity_oidc_key.minio.name
  client_id = vault_identity_oidc_client.minio.client_id
  template  = vault_identity_oidc_scope.minio_policy.template
  // Tokens issued for STS are valid for 1 hour.
  ttl = 3600
}

// A Vault policy that allows generating a MinIO STS token.
resource "vault_policy" "minio_sts" {
  name = "minio_sts"

  policy = <<EOT
  path "identity/oidc/token/${vault_identity_oidc_role.minio_sts.name}" {
    capabilities = ["read"]
  }
  EOT
}

// Give access to our user1 entity to the policy allowing the creation of signed MinIO STS tokens.
resource "vault_identity_entity_policies" "policies" {
  for_each = local.users
  policies = [
    vault_policy.minio_sts.name
  ]
  exclusive = false // In case there are other policies to be attached separately.
  entity_id = vault_identity_entity.user[each.key].id
}

// Create the OIDC provider for MinIO. This provider will be used by MinIO to authenticate users.
resource "vault_identity_oidc_provider" "minio" {
  name          = "minio"
  https_enabled = false
  issuer_host   = "vault:8200"
  allowed_client_ids = [
    vault_identity_oidc_client.minio.client_id
  ]
  scopes_supported = [
    vault_identity_oidc_scope.minio_policy.name
  ]
}

output "minio_oidc_config" {
  value = {
    config_url    = "http://${vault_identity_oidc_provider.minio.issuer_host}/v1/identity/oidc/provider/${vault_identity_oidc_provider.minio.name}/.well-known/openid-configuration"
    client_id     = vault_identity_oidc_client.minio.client_id
    client_secret = nonsensitive(vault_identity_oidc_client.minio.client_secret)
    scopes        = vault_identity_oidc_scope.minio_policy.name
    redirect_uri  = tolist(vault_identity_oidc_client.minio.redirect_uris)[0]
  }
}
