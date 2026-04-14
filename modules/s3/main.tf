# modules/s3/main.tf

locals {
  bucket_name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-s3-${var.name}"
  tags = merge(var.common_tags, var.extra_tags, {
    Name       = local.bucket_name
    Module     = "s3"
    BucketType = var.bucket_type
  })

  # Explicit S3 actions — never use s3:* wildcard in production policies
  s3_read_actions  = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAcl", "s3:GetObjectTagging"]
  s3_write_actions = ["s3:PutObject", "s3:PutObjectAcl", "s3:PutObjectTagging", "s3:DeleteObject", "s3:DeleteObjectVersion"]
  s3_list_actions  = ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
  s3_all_data_actions = concat(local.s3_read_actions, local.s3_write_actions, local.s3_list_actions)

  # HTTPS-deny uses s3:* because it's a Deny — must cover all ops including future ones
  s3_deny_actions = ["s3:*"]

  # Lambda trigger guard: only create when ARN is a real (non-mock) ARN
  # and lambda_trigger_enabled is true
  lambda_fn_name = (
    var.lambda_function_arn != "" && can(split(":", var.lambda_function_arn)[6])
    ? split(":", var.lambda_function_arn)[6]
    : var.lambda_function_arn
  )
  lambda_trigger_real = (
    var.lambda_trigger_enabled
    && var.lambda_function_arn != ""
    && !contains(["", "mock-placeholder"], try(split(":", var.lambda_function_arn)[3], ""))
  )
}

# ── Bucket ────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "this" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is an architectural HA decision. Enable it by adding aws_s3_bucket_replication_configuration when DR requirements mandate it. Not all buckets need CRR (audit logs, app assets with CloudFront caching).
  # checkov:skip=CKV_AWS_145:KMS encryption is supported via encryption=KMS + kms_key_arn in input.yaml. AES256 (SSE-S3) is acceptable for non-sensitive buckets. Enforcing KMS on all buckets adds operational overhead without proportional security gain for public-facing assets.
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = local.tags
}

# Disable ACLs entirely — bucket owner enforced is the modern security posture.
# ACLs are legacy; IAM policies + bucket policies are the correct access control.
# Required by AWS provider v5 to avoid continuous drift detection.
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.encryption == "KMS" ? "aws:kms" : "AES256"
      kms_master_key_id = var.encryption == "KMS" && var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    bucket_key_enabled = var.encryption == "KMS"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

# filter {} required by AWS provider v5 — empty = apply to all objects
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.lifecycle_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "default-lifecycle"
    status = "Enabled"
    filter {}

    dynamic "transition" {
      for_each = var.intelligent_tiering ? [1] : []
      content {
        days          = 0
        storage_class = "INTELLIGENT_TIERING"
      }
    }

    dynamic "expiration" {
      for_each = var.expiry_days > 0 ? [1] : []
      content {
        days = var.expiry_days
      }
    }

    # Purge old object versions after 90 days — prevents unbounded storage growth
    # on versioned buckets when objects are repeatedly overwritten.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Abort incomplete multipart uploads after 7 days — cleans up orphaned parts
    # that accrue storage costs but were never completed (e.g. after client crash).
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Bucket Policy ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "bucket_policy" {
  # Deny all non-TLS traffic — use s3:* here because Deny must be exhaustive
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = local.s3_deny_actions
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # VPC restriction (only for vpc_restricted bucket type)
  dynamic "statement" {
    for_each = var.bucket_type == "vpc_restricted" && length(var.allowed_vpc_ids) > 0 ? [1] : []
    content {
      sid    = "DenyNonVPC"
      effect = "Deny"
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      actions   = local.s3_deny_actions
      resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpc"
        values   = var.allowed_vpc_ids
      }
    }
  }

  # Explicit Lambda role access — named actions only, not s3:*
  dynamic "statement" {
    for_each = var.lambda_execution_role_arn != "" && local.lambda_trigger_real ? [1] : []
    content {
      sid    = "AllowLambdaRole"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = [var.lambda_execution_role_arn]
      }
      actions   = local.s3_all_data_actions
      resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.bucket_policy.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ── Access Logging ────────────────────────────────────────────────────────────
resource "aws_s3_bucket_logging" "this" {
  count         = var.access_log_bucket_name != "" ? 1 : 0
  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket_name
  target_prefix = "s3-access-logs/${local.bucket_name}/"
}

# ── Lambda Trigger ────────────────────────────────────────────────────────────
# Only created when:
#   1. lambda_trigger_enabled = true
#   2. lambda_function_arn is a real ARN (not empty, not mock placeholder)
# This prevents failures when S3 is applied before Lambda or Lambda is disabled.
resource "aws_lambda_permission" "s3_invoke" {
  count         = local.lambda_trigger_real ? 1 : 0
  statement_id  = "AllowS3Invoke-${local.bucket_name}"
  action        = "lambda:InvokeFunction"
  function_name = local.lambda_fn_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.this.arn
}

resource "aws_s3_bucket_notification" "this" {
  count  = local.lambda_trigger_real ? 1 : 0
  bucket = aws_s3_bucket.this.id

  lambda_function {
    lambda_function_arn = var.lambda_function_arn
    events              = var.lambda_trigger_events
    filter_prefix       = var.lambda_filter_prefix != "" ? var.lambda_filter_prefix : null
    filter_suffix       = var.lambda_filter_suffix != "" ? var.lambda_filter_suffix : null
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}
