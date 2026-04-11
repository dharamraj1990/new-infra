# =============================================================================
# ROOT terragrunt.hcl
#
# Resource naming convention:
#   <name_prefix>-<region>-<project>-<type>-<name>
#
# name_prefix comes from accounts.yaml, NOT from environment string.
# This means:
#   account: mamstg  → name_prefix=stg  → stg-ap-south-1-mam-s3-assets
#   account: mamprd  → name_prefix=prd  → prd-ap-south-1-mam-s3-assets
#   account: tvplusdev → name_prefix=dev → dev-ap-south-1-tvplus-ec2-api
#
# environment is still used for:
#   - tags (Environment tag)
#   - state bucket key path
#   - GitHub environment gates
# =============================================================================

locals {
  input       = yamldecode(file("${get_repo_root()}/input.yaml"))
  accounts    = yamldecode(file("${get_repo_root()}/accounts/accounts.yaml"))

  # Account key comes from TF_ACCOUNT_KEY env var (set by CI from the workflow dropdown).
  # For local runs, fall back to data["account"] in input.yaml if still present.
  account_key = get_env("TF_ACCOUNT_KEY", try(local.input.account, ""))
  account_cfg = local.accounts[local.account_key]

  # All stack metadata comes from accounts/accounts.yaml via the account key.
  # input.yaml contains only: account (selector), metadata (tags), resources.
  environment = local.account_cfg.environment
  name_prefix = local.account_cfg.name_prefix
  region      = local.account_cfg.region
  account_id  = local.account_cfg.account_id
  project     = local.account_cfg.project_name

  # Common tags (all optional — try() with safe defaults).
  # Known structured fields are read individually; everything else in tags: flows
  # through as-is so users can add arbitrary common tags without touching this file.
  stage       = try(local.input.tags.stage,       local.environment)
  owner       = try(local.input.tags.owner,       try(local.account_cfg.owner, "unknown"))
  component   = try(local.input.tags.component,   "general")
  cost_center = try(local.input.tags.cost_center, try(local.account_cfg.cost_center, ""))
  # All tags: entries that are NOT one of the structured fields above become extra tags
  global_extra_tags = {for k, v in try(local.input.tags, {}) : k => v if !contains(["stage", "owner", "component", "cost_center"], k)}

  # State backend — S3 native locking (Terraform 1.10+), no DynamoDB needed
  mgmt_account_id   = get_env("MGMT_ACCOUNT_ID", local.account_id)
  tf_state_bucket   = "tfstate-${local.mgmt_account_id}-${local.region}"
  tf_state_key      = "${local.environment}/${local.region}/${local.project}/${path_relative_to_include()}/terraform.tfstate"

  # Tags — Environment tag uses full env name, not the short prefix
  common_tags = merge(local.global_extra_tags, {
    Environment = local.environment
    Stage       = local.stage
    Project     = local.project
    Component   = local.component
    Owner       = local.owner
    CostCenter  = local.cost_center
    Region      = local.region
    AccountId   = local.account_id
    Account     = local.account_key
    ManagedBy   = "terragrunt"
  })
}

# ── Remote State ──────────────────────────────────────────────────────────────
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.tf_state_bucket
    key          = local.tf_state_key
    region       = local.region
    encrypt      = true
    use_lockfile = true    # S3 native locking — no DynamoDB table needed
  }
}

# ── AWS Provider ──────────────────────────────────────────────────────────────
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-TFEOF
    terraform {
      required_version = ">= 1.10.0"
      required_providers {
        aws = { source = "hashicorp/aws", version = "~> 5.0" }
        tls = { source = "hashicorp/tls", version = "~> 4.0" }
      }
    }
    provider "aws" {
      region = "${local.region}"
    }
    provider "aws" {
      alias  = "us_east_1"
      region = "us-east-1"
    }
  TFEOF
}

# ── Inputs passed to every module ────────────────────────────────────────────
inputs = {
  environment  = local.environment
  name_prefix  = local.name_prefix   # <<< drives ALL resource naming
  aws_region   = local.region
  project_name = local.project
  account_id   = local.account_id
  common_tags  = local.common_tags
}
