# bootstrap/oidc_mgmt/main.tf
# Run ONCE in management account.
# Creates OIDC provider, github-oidc-role, TF state bucket.
# S3 native locking (use_lockfile) replaces DynamoDB — no lock table needed.
# S3 bucket policy grants target account roles direct access (no role_arn in backend).

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "mgmt_account_id" {
  type = string
}

variable "target_account_ids" {
  type = list(string)
}

variable "target_role_name" {
  type    = string
  default = "deploy-role"
}

variable "tf_state_bucket_name" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "protected_branches" {
  type        = list(string)
  default     = ["main"]
  description = "Branches allowed to trigger deployments via this OIDC role. Wildcard (*) is intentionally NOT used."
}

# ── KMS key for TF state bucket ───────────────────────────────────────────────
resource "aws_kms_key" "tf_state" {
  description             = "KMS key for Terraform state bucket encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = { ManagedBy = "terraform", Purpose = "tf-state-encryption" }
}

resource "aws_kms_alias" "tf_state" {
  name          = "alias/tf-state-key"
  target_key_id = aws_kms_key.tf_state.key_id
}

# ── OIDC Provider ──────────────────────────────────────────────────────────────
# Dynamic thumbprint — auto-rotates when GitHub changes their TLS cert
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ── OIDC Role ──────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "oidc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Scope to specific protected branches only — never use a wildcard "*" here.
    # environment:* allows GitHub environment-gated jobs (approval gates).
    # ref:refs/heads/<branch> allows workflow_dispatch / push from that branch.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for b in var.protected_branches : "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${b}"],
        ["repo:${var.github_org}/${var.github_repo}:environment:*"]
      )
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_oidc" {
  name               = "github-oidc-role"
  assume_role_policy = data.aws_iam_policy_document.oidc_assume.json
  tags               = { ManagedBy = "terraform" }
}

data "aws_iam_policy_document" "oidc_perms" {
  statement {
    sid       = "AssumeTargetRoles"
    actions   = ["sts:AssumeRole"]
    resources = [for id in var.target_account_ids : "arn:aws:iam::${id}:role/${var.target_role_name}"]
  }

  statement {
    sid = "TFState"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
    ]
    resources = [
      "arn:aws:s3:::${var.tf_state_bucket_name}",
      "arn:aws:s3:::${var.tf_state_bucket_name}/*",
    ]
  }

  statement {
    sid = "TFStateKMS"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.tf_state.arn]
  }
}

resource "aws_iam_role_policy" "oidc" {
  name   = "oidc-perms"
  role   = aws_iam_role.github_oidc.name
  policy = data.aws_iam_policy_document.oidc_perms.json
}

# ── TF State Bucket ───────────────────────────────────────────────────────────
resource "aws_s3_bucket" "tf_state" {
  bucket = var.tf_state_bucket_name
  tags   = { ManagedBy = "terraform", Purpose = "tf-state" }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tf_state.arn
    }
    bucket_key_enabled = true  # reduces KMS API call cost ~99%
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Grant target roles direct S3 access (no role_arn in Terragrunt backend)
data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tf_state.arn, "${aws_s3_bucket.tf_state.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowRoles"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = concat(
        ["arn:aws:iam::${var.mgmt_account_id}:role/github-oidc-role"],
        [for id in var.target_account_ids : "arn:aws:iam::${id}:role/${var.target_role_name}"]
      )
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
    ]
    resources = [aws_s3_bucket.tf_state.arn, "${aws_s3_bucket.tf_state.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "tf_state" {
  bucket     = aws_s3_bucket.tf_state.id
  policy     = data.aws_iam_policy_document.bucket_policy.json
  depends_on = [aws_s3_bucket_public_access_block.tf_state]
}

# NOTE: DynamoDB lock table removed — Terraform 1.10+ supports S3 native locking
# via use_lockfile = true in the S3 backend config (set in root terragrunt.hcl).

output "oidc_role_arn" {
  value = aws_iam_role.github_oidc.arn
}

output "tf_state_bucket" {
  value = aws_s3_bucket.tf_state.bucket
}

output "tf_state_kms_key_arn" {
  value       = aws_kms_key.tf_state.arn
  description = "KMS key ARN used for state bucket SSE — add to target_role KMSRead resources if you want to scope it further"
}
