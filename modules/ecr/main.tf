# modules/ecr/main.tf
locals {
  repo_name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-ecr-${var.name}"
  tags = merge(var.common_tags, var.extra_tags, { Name = local.repo_name, Module = "ecr" })
}

resource "aws_ecr_repository" "this" {
  name                 = local.repo_name
  image_tag_mutability = var.tag_immutability ? "IMMUTABLE" : "MUTABLE"
  force_delete         = var.force_delete

  encryption_configuration {
    encryption_type = var.encryption == "KMS" ? "KMS" : "AES256"
    kms_key         = var.encryption == "KMS" && var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = local.tags
}

# Enhanced scanning uses Inspector v2 for continuous CVE scanning (vs basic scan-on-push).
# This is a registry-level setting — one per account, so this resource is idempotent.
# Enhanced scanning gives continuous vulnerability detection instead of one-shot scans.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = var.scan_type

  dynamic "rule" {
    for_each = var.scan_type == "ENHANCED" ? [1] : []
    content {
      scan_frequency = "CONTINUOUS_SCAN"
      repository_filter {
        filter      = "*"
        filter_type = "WILDCARD"
      }
    }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.max_image_count} images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.max_image_count }
      action       = { type = "expire" }
    }]
  })
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ecr_policy" {
  # Pull access for explicitly listed principals (or account root as fallback).
  # NOTE: ecr:GetAuthorizationToken is account-level (resource = *) and must be
  # granted separately via IAM identity policy — it cannot be set here.
  statement {
    sid    = "AllowPull"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = length(var.allowed_principal_arns) > 0 ? var.allowed_principal_arns : ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
  }

  dynamic "statement" {
    for_each = var.lambda_integration_enabled ? [1] : []
    content {
      sid    = "AllowLambdaPull"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["lambda.amazonaws.com"]
      }
      actions = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.ecr_policy.json
}
