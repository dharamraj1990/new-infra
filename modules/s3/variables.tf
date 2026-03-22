variable "name" {
  type = string
}
variable "environment" {
  type = string
}
variable "name_prefix" {
  type        = string
  description = "Short prefix for all resource names derived from account (e.g. stg, prd, dev)"
}

variable "aws_region" {
  type = string
}
variable "project_name" {
  type = string
}
variable "common_tags" {
  type = map(string)
  default = {}
}
variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Per-resource extra tags merged on top of common_tags"
}


variable "bucket_type" {
  type    = string
  default = "standard"
}

variable "versioning" {
  type = bool
  default = true
}
variable "force_destroy" {
  type = bool
  default = false
}
variable "lifecycle_enabled" {
  type = bool
  default = true
}
variable "intelligent_tiering" {
  type = bool
  default = true
}
variable "expiry_days" {
  type = number
  default = 0
}
variable "encryption" {
  type = string
  default = "AES256"
}
variable "kms_key_arn" {
  type = string
  default = ""
}
variable "allowed_vpc_ids" {
  type = list(string)
  default = []
}
variable "access_log_bucket_name" {
  type = string
  default = ""
}

variable "lambda_trigger_enabled" {
  type = bool
  default = false
}
variable "lambda_function_arn" {
  type = string
  default = ""
}
variable "lambda_execution_role_arn" {
  type = string
  default = ""
}
variable "lambda_trigger_events" {
  type = list(string)
  default = ["s3:ObjectCreated:*"]
}
variable "lambda_filter_prefix" {
  type = string
  default = ""
}
variable "lambda_filter_suffix" {
  type = string
  default = ""
}
