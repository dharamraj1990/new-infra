# AWS Terragrunt Infrastructure Framework

Multi-account AWS infrastructure with Terragrunt + GitHub Actions OIDC.
Single `input.yaml` drives everything — no nested region folders.

## Structure

```
aws-infra-v2/
├── input.yaml                   ← EDIT THIS — declare all resources here
├── terragrunt.hcl               ← root config, reads input.yaml
├── accounts/accounts.yaml       ← account IDs + role names
├── modules/
│   ├── s3/        main.tf · variables.tf · outputs.tf
│   ├── lambda/    main.tf · variables.tf · outputs.tf · placeholder.zip
│   ├── sns/       main.tf · variables.tf · outputs.tf
│   ├── sqs/       main.tf · variables.tf · outputs.tf
│   ├── ecr/       main.tf · variables.tf · outputs.tf
│   ├── ec2/       main.tf · variables.tf · outputs.tf
│   └── cloudfront/main.tf · variables.tf · outputs.tf
├── scripts/
│   ├── generate_configs.py      ← input.yaml → live/dev/<type>-<name>/terragrunt.hcl
│   ├── get_account_info.py      ← safe YAML lookup used by CI
│   └── cost_estimate.py         ← infracost on tfplan files → step summary
├── bootstrap/
│   ├── oidc_mgmt/main.tf        ← run once in management account
│   └── target_role/main.tf      ← run once in each target account
└── .github/workflows/
    ├── deploy.yml               ← OIDC → plan → cost → approval → apply
    ├── destroy.yml              ← double-confirmed destroy
    └── drift-detection.yml      ← nightly drift scan → GitHub Issue
```

## Quick start

### 1. Bootstrap (one time)

```bash
# Management account
cd bootstrap/oidc_mgmt
terraform apply \
  -var="github_org=YOUR_ORG" \
  -var="github_repo=YOUR_REPO" \
  -var="mgmt_account_id=111111111111" \
  -var="target_account_ids=[\"533269020590\"]" \
  -var="target_role_name=admin-role" \
  -var="tf_state_bucket_name=tfstate-111111111111-ap-south-1"

# Each target account
cd bootstrap/target_role
terraform apply \
  -var="mgmt_account_id=111111111111" \
  -var="role_name=admin-role"
```

### 2. Update accounts/accounts.yaml with real IDs

### 3. Add GitHub Secrets

| Secret | Value |
|---|---|
| `MGMT_ACCOUNT_ID` | Management account 12-digit ID |
| `MGMT_ROLE_NAME` | `github-oidc-role` |
| ~~`INFRACOST_API_KEY`~~ | **Removed** — cost estimation now uses AWS Pricing API via boto3 (no third-party) |

### 4. Add GitHub Variables

| Variable | Value |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `PROJECT_NAME` | `op2mise` |

### 5. Create GitHub Environments

| Environment | Required reviewers | Purpose |
|---|---|---|
| `dev-plan` | none | plan step |
| `dev-approval` | your team | approval gate (auto-emails reviewers) |
| `dev-apply` | none | apply step |

### 6. Edit input.yaml and push

```bash
# Edit input.yaml to enable/configure the resources you want
git add input.yaml
git commit -m "feat: add S3 and Lambda"
git push origin main
# → deploy.yml triggers → plan → cost estimate → email approval → apply
```

## Naming convention

All resources: `<env>-<region>-<project>-<type>-<name>`

Example: `dev-ap-south-1-op2mise-lambda-image-processor`

## Resource types supported

| Type | Key features |
|---|---|
| `s3` | standard/logging/vpc-restricted, lifecycle filter fix, access logging by bucket name, lambda trigger |
| `lambda` | Zip or container (Image), arm64 default, SQS/SNS triggers, service access policies |
| `sns` | FIFO/standard, subscriptions, KMS |
| `sqs` | FIFO/standard, DLQ, lambda event source mapping |
| `ecr` | lifecycle, scan, immutability, lambda integration |
| `ec2` | auto-AMI, arm64/x86, ASG, IMDSv2, key in Secrets Manager, ignore_changes prevents destroy loop |
| `cloudfront` | S3/ALB/custom origin, OAC, WAF, caching, logging |

## Bug fixes vs previous version

| Bug | Fix |
|---|---|
| Lambda `package_type = "zip"` rejected | Split into `.zip` and `.image` resources; `"Zip"`/`"Image"` casing |
| Lambda `filename` must be specified | `placeholder.zip` bundled in module — used when no real zip provided |
| S3 lifecycle `filter` warning | Empty `filter {}` block added (required by AWS provider v5) |
| S3 logging `InvalidBucketName` | `target_bucket` takes bucket name string, not domain name |
| Dependency "detected no outputs" | `mock_outputs_allowed_terraform_commands = ["validate","plan","destroy"]` |
| EC2 destroyed on every re-run | `lifecycle { ignore_changes = [latest_version] }` on launch template; `ignore_changes = [ami, launch_template]` on instance |
| Nested region/project folders | Flat `live/<env>/<type>-<name>/` — region and project from `input.yaml` only |
| Multiple input files (env.hcl, region.hcl, account.hcl) | Single `input.yaml` at repo root |
| Inline `python3 -c` quote failures | `scripts/get_account_info.py` CLI helper |
| Double assume_role in terragrunt | Root `terragrunt.hcl` uses ambient credentials — no `assume_role` block |
