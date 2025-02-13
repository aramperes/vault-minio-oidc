# vault-minio-oidc

Delegating [MinIO](https://min.io/) [S3](https://aws.amazon.com/s3/) authentication to [Vault](https://www.vaultproject.io/), using [`AssumeRoleWithWebIdentity`](https://min.io/docs/minio/linux/developers/security-token-service/AssumeRoleWithWebIdentity.html) and [OpenID Connect](https://en.wikipedia.org/wiki/OpenID).

## Startup

```bash
docker-compose up -d
```

- Vault UI: http://127.0.0.1:8200 (root token: `testtoken`)
- MinIO API: http://127.0.0.1:9000
- MinIO Console: http://127.0.0.1:9001 (`admin/admin123`)

## Configure Vault OIDC

An example can be bootstrapped using Terraform:

```bash
cd tf/
tf apply
```

This will print the information you need to configure the MinIO OIDC provider. Example:

```hcl
minio_oidc_config = {
  "client_id" = "pvab37x3NgR4I8TW83do9LQMQkrQe0Kv"
  "client_secret" = "hvo_secret_RN2tw7wi8bVWKSyDMdTF6WNghcwflfaeNdKKwDtG8NwWaXeQcfid5v0EBeJdYplU"
  "config_url" = "http://vault:8200/v1/identity/oidc/provider/minio/.well-known/openid-configuration"
  "redirect_uri" = "http://localhost:9001/oauth_callback"
  "scopes" = "minio_policy"
}
```

## Get MinIO credentials through STS

First, login to Vault using our test user with its password (or other mechanism). This will return a Vault token.

```bash
curl -XPOST --data '{"password": "changeme"}' http://127.0.0.1:8200/v1/auth/userpass/login/user1 | jq -r .auth.client_token
export USER1_VAULT="..."
```

Now, we can get a JSON Web Token (JWT) that MinIO will trust from Vault:

```bash
curl -H 'X-Vault-Token: $USER1_VAULT' http://127.0.0.1:8200/v1/identity/oidc/token/minio | jq -r .data.token
export USER1_JWT="..."
```

If decoded, the JWT looks like:

```json
{
    "aud": "pvab37x3NgR4I8TW83do9LQMQkrQe0Kv",
    "exp": 1739387745,
    "iat": 1739384145,
    "iss": "http://0.0.0.0:8200/v1/identity/oidc",
    "namespace": "root",
    "policy": "readonly",
    "sub": "f17856fb-ccaf-22d9-c1de-0ed1040c6424"
}
```

And we can use this JWT with MinIO's `AssumeRoleWithWebIdentity` STS endpoint to obtain a temporary API key pair.
This key pair will have the MinIO policies that are listed on the Vault user's entity metadata, and were propagated to the `policy` claim.

```bash
curl -XPOST "http://127.0.0.1:9000/?Action=AssumeRoleWithWebIdentity&Version=2011-06-15&DurationSeconds=3600&WebIdentityToken=$USER1_JWT"
```

This gives you back the access/secret key pair valid for 1 hour:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AssumeRoleWithWebIdentityResponse
	xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
	<AssumeRoleWithWebIdentityResult>
		<AssumedRoleUser>
			<Arn></Arn>
			<AssumeRoleId></AssumeRoleId>
		</AssumedRoleUser>
		<Credentials>
			<AccessKeyId>LV20XAD6FYRNE2O6PI8U</AccessKeyId>
			<SecretAccessKey>SEwmpmPIVIvsW2ZPhylDKA6tkQNg4IanF1KvrdcB</SecretAccessKey>
			<SessionToken>eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJhY2Nlc3NLZXkiOiJMVjIwWEFENkZZUk5FMk82UEk4VSIsImF1ZCI6InB2YWIzN3gzTmdSNEk4VFc4M2RvOUxRTVFrclFlMEt2IiwiZXhwIjoxNzM5Mzg4MDUzLCJpYXQiOjE3MzkzODQxNDUsImlzcyI6Imh0dHA6Ly8wLjAuMC4wOjgyMDAvdjEvaWRlbnRpdHkvb2lkYyIsIm5hbWVzcGFjZSI6InJvb3QiLCJwb2xpY3kiOiJyZWFkb25seSIsInN1YiI6ImYxNzg1NmZiLWNjYWYtMjJkOS1jMWRlLTBlZDEwNDBjNjQyNCJ9.nWXSLB_GCTRAiyd_62otGWuEWIy8pDSjqaWtT_zh2Fvb_W0GgN2siGjLgjV2CzOHcTXEOpHpmdNSRgc_lbnPOw</SessionToken>
			<Expiration>2025-02-12T19:20:53Z</Expiration>
		</Credentials>
		<SubjectFromWebIdentityToken>f17856fb-ccaf-22d9-c1de-0ed1040c6424</SubjectFromWebIdentityToken>
	</AssumeRoleWithWebIdentityResult>
</AssumeRoleWithWebIdentityResponse>
```

## Test credentials

In order to use these credentials with the S3 API, you will need all 3 values returned (AccessKeyId, SecretAccessKey, SessionToken):

```toml
# ~/.aws/credentials
[minio]
aws_access_key_id = LV20XAD6FYRNE2O6PI8U
aws_secret_access_key = SEwmpmPIVIvsW2ZPhylDKA6tkQNg4IanF1KvrdcB
aws_session_token = eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJhY2Nlc3NLZXkiOiJMVjIwWEFENkZZUk5FMk82UEk4VSIsImF1ZCI6InB2YWIzN3gzTmdSNEk4VFc4M2RvOUxRTVFrclFlMEt2IiwiZXhwIjoxNzM5Mzg4MDUzLCJpYXQiOjE3MzkzODQxNDUsImlzcyI6Imh0dHA6Ly8wLjAuMC4wOjgyMDAvdjEvaWRlbnRpdHkvb2lkYyIsIm5hbWVzcGFjZSI6InJvb3QiLCJwb2xpY3kiOiJyZWFkb25seSIsInN1YiI6ImYxNzg1NmZiLWNjYWYtMjJkOS1jMWRlLTBlZDEwNDBjNjQyNCJ9.nWXSLB_GCTRAiyd_62otGWuEWIy8pDSjqaWtT_zh2Fvb_W0GgN2siGjLgjV2CzOHcTXEOpHpmdNSRgc_lbnPOw
```

Example, list buckets with [s5cmd](https://github.com/peak/s5cmd):

```bash
s5cmd --profile minio --endpoint-url=http://localhost:9000 ls
```

## Diagrams

This is a representation of the Vault configuration for this proof of concept, as defined in `tf/vault.tf`:

![Vault OIDC Diagram](./.github/vault-oidc.png)