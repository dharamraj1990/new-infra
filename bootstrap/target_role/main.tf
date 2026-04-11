# bootstrap/target_role/main.tf
# Run in EACH target account.
# Creates a deploy role with least-privilege permissions scoped to the
# resource types this framework manages — NOT AdministratorAccess.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "mgmt_account_id" {
  type = string
}

variable "role_name" {
  type    = string
  default = "deploy-role"
}

variable "tf_state_bucket_prefix" {
  type        = string
  default     = "tfstate-"
  description = "Prefix for the TF state bucket name (for cross-account S3 access)"
}

data "aws_caller_identity" "current" {}

# ── Trust Policy ───────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.mgmt_account_id}:role/github-oidc-role"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "terraform" }
}

# ── Least-privilege policy scoped to framework-managed resource types ─────────
data "aws_iam_policy_document" "deploy_perms" {
  # S3 — buckets, policies, notifications, encryption, logging, lifecycle, versioning, public access block
  statement {
    sid = "S3Manage"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:Get*",
      "s3:List*",
      "s3:Put*",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["*"]
  }

  # Lambda — functions, event source mappings, permissions, layers
  statement {
    sid = "LambdaManage"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:Get*",
      "lambda:List*",
      "lambda:Update*",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:PublishVersion",
      "lambda:CreateAlias",
      "lambda:DeleteAlias",
      "lambda:UpdateAlias",
    ]
    resources = ["*"]
  }

  # SQS — queues, policies
  statement {
    sid = "SQSManage"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:Get*",
      "sqs:List*",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = ["*"]
  }

  # SNS — topics, subscriptions, policies
  statement {
    sid = "SNSManage"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:Get*",
      "sns:List*",
      "sns:Set*",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = ["*"]
  }

  # ECR — repositories, lifecycle policies
  statement {
    sid = "ECRManage"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "ecr:Put*",
      "ecr:Set*",
      "ecr:DeleteLifecyclePolicy",
      "ecr:DeleteRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
    ]
    resources = ["*"]
  }

  # EC2 — instances, security groups, key pairs, launch templates, ASG
  statement {
    sid = "EC2Manage"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:Describe*",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroup*",
      "ec2:RevokeSecurityGroup*",
      "ec2:CreateKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:ImportKeyPair",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:DeleteLaunchTemplate",
      "ec2:ModifyLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = ["*"]
  }

  # Auto Scaling
  statement {
    sid = "ASGManage"
    actions = [
      "autoscaling:CreateAutoScalingGroup",
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
      "autoscaling:Describe*",
      "autoscaling:CreateOrUpdateTags",
      "autoscaling:DeleteTags",
      "autoscaling:SetDesiredCapacity",
    ]
    resources = ["*"]
  }

  # CloudFront — distributions, OAC, cache policies
  statement {
    sid = "CloudFrontManage"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:CreateCachePolicy",
      "cloudfront:DeleteCachePolicy",
      "cloudfront:GetCachePolicy",
      "cloudfront:UpdateCachePolicy",
      "cloudfront:CreateOriginRequestPolicy",
      "cloudfront:DeleteOriginRequestPolicy",
      "cloudfront:GetOriginRequestPolicy",
    ]
    resources = ["*"]
  }

  # WAFv2 — web ACLs for CloudFront
  statement {
    sid = "WAFManage"
    actions = [
      "wafv2:CreateWebACL",
      "wafv2:DeleteWebACL",
      "wafv2:GetWebACL",
      "wafv2:UpdateWebACL",
      "wafv2:ListWebACLs",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "wafv2:ListTagsForResource",
      "wafv2:TagResource",
      "wafv2:UntagResource",
    ]
    resources = ["*"]
  }

  # IAM — roles, policies, instance profiles (scoped to framework-created resources)
  statement {
    sid = "IAMManage"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs — log groups for Lambda
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = ["*"]
  }

  # Secrets Manager — EC2 private keys
  statement {
    sid = "SecretsManage"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:RestoreSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecrets",
    ]
    resources = ["*"]
  }

  # KMS — for encrypted resources
  statement {
    sid = "KMSRead"
    actions = [
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
  }

  # TF state — cross-account access to mgmt state bucket
  statement {
    sid = "TFStateBucket"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
    ]
    resources = [
      "arn:aws:s3:::${var.tf_state_bucket_prefix}*",
      "arn:aws:s3:::${var.tf_state_bucket_prefix}*/*",
    ]
  }

  # STS — for caller identity lookups in modules
  statement {
    sid       = "STSGetCaller"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.role_name}-policy"
  policy = data.aws_iam_policy_document.deploy_perms.json
  tags   = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}

output "role_arn" {
  value = aws_iam_role.deploy.arn
}

output "role_name" {
  value = aws_iam_role.deploy.name
}
