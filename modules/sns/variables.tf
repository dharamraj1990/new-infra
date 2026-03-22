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

variable "fifo" {
  type    = bool
  default = false
}
variable "content_based_deduplication" {
  type    = bool
  default = false
}
variable "display_name" {
  type    = string
  default = ""
}
variable "kms_key_arn" {
  type        = string
  default     = "alias/aws/sns"
  description = "KMS key for SNS encryption. Defaults to AWS-managed SNS key. Set empty to disable."
}
variable "allowed_role_arns" {
  type    = list(string)
  default = []
}
variable "subscriptions" {
  type = list(object({
    protocol = string
    endpoint = string
  }))
  default = []
}
