resource "vault_identity_oidc_key" "test" {
  name               = "my-key"
  allowed_client_ids = ["*"]
  rotation_period    = 3600
  verification_ttl   = 3600
}

resource "vault_identity_oidc_assignment" "test" {
  name       = "my-assignment"
  entity_ids = ["fake-ascbascas-2231a-sdfaa"]
  group_ids  = ["fake-sajkdsad-32414-sfsada"]
}

resource "vault_identity_oidc_client" "test" {
  name          = "application"
  key           = vault_identity_oidc_key.test.name
  redirect_uris = [
  ]
  assignments = [
    vault_identity_oidc_assignment.test.name
  ]
  id_token_ttl     = 2400
  access_token_ttl = 7200
}

resource "vault_identity_oidc_scope" "test" {
  name        = "groups"
  template    = jsonencode(
  {
    groups = "{{identity.entity.groups.names}}",
  }
  )
  description = "Groups scope."
}

resource "vault_identity_oidc_provider" "test" {
  name = "my-provider"
  https_enabled = false
  issuer_host = "vault:8200"
  allowed_client_ids = [
    vault_identity_oidc_client.test.client_id
  ]
  scopes_supported = [
    vault_identity_oidc_scope.test.name
  ]
}
