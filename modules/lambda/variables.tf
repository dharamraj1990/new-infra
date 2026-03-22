variable "name"         { type = string }
variable "environment"  { type = string }
variable "name_prefix" {
  type        = string
  description = "Short prefix for all resource names derived from account (e.g. stg, prd, dev)"
}

variable "aws_region"   { type = string }
variable "project_name" { type = string }
variable "common_tags" {
  type    = map(string)
  default = {}
}
variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Per-resource extra tags merged on top of common_tags"
}

variable "package_type" {
  type    = string
  default = "zip"
}
variable "runtime" {
  type    = string
  default = "python3.12"
}
variable "handler" {
  type    = string
  default = "handler.main"
}
variable "arch" {
  type    = string
  default = "arm64"
}
variable "timeout" {
  type    = number
  default = 30
}
variable "memory_size" {
  type    = number
  default = 512
}
variable "log_retention_days" {
  type    = number
  default = 14
}
variable "filename" {
  type    = string
  default = null
}
variable "source_code_hash" {
  type    = string
  default = null
}
variable "image_uri" {
  type    = string
  default = null
}
variable "image_command" {
  type    = list(string)
  default = []
}
variable "image_entry_point" {
  type    = list(string)
  default = []
}
variable "image_working_directory" {
  type    = string
  default = null
}
variable "environment_variables" {
  type    = map(string)
  default = {}
}
variable "service_access" {
  type    = list(string)
  default = []
}

# ── Resource ARN scoping for service_access ─────────────────────────────────
# When provided, IAM policies are scoped to these ARNs instead of "*".
variable "s3_resource_arns" {
  type        = list(string)
  default     = []
  description = "S3 bucket ARNs to scope s3 service_access to. Empty = all buckets."
}

variable "sqs_resource_arns" {
  type        = list(string)
  default     = []
  description = "SQS queue ARNs to scope sqs service_access to. Empty = all queues."
}

variable "sns_resource_arns" {
  type        = list(string)
  default     = []
  description = "SNS topic ARNs to scope sns service_access to. Empty = all topics."
}

variable "dynamodb_resource_arns" {
  type        = list(string)
  default     = []
  description = "DynamoDB table ARNs to scope dynamodb service_access to. Empty = all tables."
}

variable "ssm_resource_arns" {
  type        = list(string)
  default     = []
  description = "SSM parameter ARNs to scope ssm service_access to. Empty = all parameters."
}

variable "secretsmanager_resource_arns" {
  type        = list(string)
  default     = []
  description = "Secrets Manager secret ARNs to scope access to. Empty = all secrets."
}

variable "iam_role_create" {
  type    = bool
  default = true
}
variable "iam_role_arn" {
  type    = string
  default = ""
}
variable "iam_role_name" {
  type    = string
  default = ""
}
variable "permission_boundary" {
  type    = string
  default = ""
}
variable "vpc_enabled" {
  type    = bool
  default = false
}
variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC ID — required when vpc_enabled=true"
}
variable "subnet_ids" {
  type        = list(string)
  default     = []
  description = "Subnet IDs for Lambda ENIs — required when vpc_enabled=true"
}
variable "sg_create" {
  type    = bool
  default = true
}
variable "existing_sg_ids" {
  type    = list(string)
  default = []
}
variable "sns_trigger_enabled" {
  type    = bool
  default = false
}
variable "sns_topic_arn" {
  type    = string
  default = ""
}
variable "sqs_trigger_enabled" {
  type    = bool
  default = false
}
variable "sqs_queue_arn" {
  type    = string
  default = ""
}
variable "sqs_batch_size" {
  type    = number
  default = 10
}
