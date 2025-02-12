// First, we need some sort of authentication backend to authenticate users.
// We will use the userpass backend for this example.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

// Create a user in the userpass backend with the username "user1" and password "changeme".
resource "vault_generic_endpoint" "user1" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/user1"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "changeme"
  })
}

// Creates an entity to represent the user in Vault. The entity has a list of MinIO policies attached to it.
// An entity can have multiple aliases, which are used to authenticate the entity.
resource "vault_identity_entity" "user1" {
  name     = "user1"
  policies = [vault_policy.minio_sts.name]
  metadata = {
    minio_policies = "readonly"
  }
}

// Create an alias for the user in the userpass backend, and tie it to the entity we created above.
resource "vault_identity_entity_alias" "test" {
  name           = "user1"
  mount_accessor = vault_auth_backend.userpass.accessor
  canonical_id   = vault_identity_entity.user1.id
}

// Next, we create an "assigmment" which is used to determine which entities are allowed to access a particular client (MinIO).
resource "vault_identity_oidc_assignment" "minio_users" {
  name = "minio_users"
  entity_ids = [
    vault_identity_entity.user1.id,
  ]
  group_ids = []
}

// We create the OIDC client for MinIO. This client will be used by MinIO to authenticate users.
// A client ID and client secret will be available in the Vault UI to be pasted into the MinIO configuration.
resource "vault_identity_oidc_client" "minio" {
  name = "minio"
  key  = vault_identity_oidc_key.minio.name
  redirect_uris = [
    "http://localhost:9001/oauth_callback"
  ]
  assignments = [
    vault_identity_oidc_assignment.minio_users.name
  ]
  id_token_ttl     = 3600
  access_token_ttl = 3600
}

// Create a signing key for the OIDC client.
resource "vault_identity_oidc_key" "minio" {
  name             = "minio"
  algorithm        = "RS256"
  rotation_period  = 3600
  verification_ttl = 3600
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

// A Vault policy that allows generating a MinIO STS token.
// Note; the policy refers to a resource that doesn't exist yet otherwise it creates a cycle.
resource "vault_policy" "minio_sts" {
  name = "minio_sts"

  policy = <<EOT
path "identity/oidc/token/minio" {
  capabilities = ["read"]
}
EOT
}

// In order to allow issuing manual tokens (for STS), we need to create a role for the MinIO client.
// For MinIO to accept the tokens, it must have the same client_id as the client application.
resource "vault_identity_oidc_role" "minio" {
  name      = "minio"
  key       = vault_identity_oidc_key.minio.name
  client_id = vault_identity_oidc_client.minio.client_id
  ttl       = 3600
  template  = vault_identity_oidc_scope.minio_policy.template
}

// Allow the MinIO STS to use the signing key.
resource "vault_identity_oidc_key_allowed_client_id" "minio_sts" {
  key_name          = vault_identity_oidc_key.minio.name
  allowed_client_id = vault_identity_oidc_role.minio.client_id
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
