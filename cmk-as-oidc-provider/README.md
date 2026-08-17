# CMK as an OIDC Provider (AWS IRSA)

Lets pods on Crusoe Managed Kubernetes (CMK) assume AWS IAM roles directly, without static AWS credentials — using CMK's cluster OIDC issuer as the identity provider for AWS IAM Roles for Service Accounts (IRSA).

Use when a workload running on CMK needs to talk to AWS services (S3, etc.) and you want short-lived, per-ServiceAccount AWS credentials instead of long-lived access keys baked into a Secret.

## How it works

1. The CMK cluster's OIDC issuer is registered as an identity provider in AWS IAM (one-time setup, outside this repo — see your AWS IAM console or `aws iam create-open-id-connect-provider`).
2. An AWS IAM role is created with a trust policy scoped to a specific Kubernetes ServiceAccount (namespace + name), authenticated via the cluster's OIDC issuer.
3. Pods that mount a projected service account token (audience `sts.amazonaws.com`) and set the `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` env vars can then call `aws sts assume-role-with-web-identity` transparently — the AWS SDK/CLI does this automatically when both env vars are present.

## Usage

1. Set up the OIDC trust relationship and IAM role in AWS (prerequisite, not included here).
2. Edit [pod-using-s3-with-oidc-sa.yaml](./pod-using-s3-with-oidc-sa.yaml) and replace `<YOUR AWS ACCOUNT ID>` and `<ROLE NAME>` with your IAM role's account ID and role name (both `role-arn` annotation and `AWS_ROLE_ARN` env var).
3. Apply it:

```bash
kubectl apply -f pod-using-s3-with-oidc-sa.yaml
```

The pod creates a timestamped S3 bucket, writes a test object, lists it, then exits — confirming the ServiceAccount can assume the AWS role and reach S3 with no static credentials involved.

```bash
kubectl logs amazon-s3-test
```

## Notes

- `expirationSeconds: 86400` on the projected token — adjust to your security posture; AWS STS sessions are re-derived from this token, not the STS session duration itself.
- The AWS CLI/SDK needs no explicit credential configuration — `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` are picked up automatically by the default credential provider chain.
