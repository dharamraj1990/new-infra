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

variable "tag_immutability" {
  type = bool
  default = true
}
variable "scan_on_push" {
  type = bool
  default = true
}
variable "force_delete" {
  type = bool
  default = false
}
variable "max_image_count" {
  type = number
  default = 10
}
variable "encryption" {
  type = string
  default = "AES256"
}
variable "kms_key_arn" {
  type = string
  default = ""
}
variable "allowed_principal_arns" {
  type = list(string)
  default = []
}
variable "lambda_integration_enabled" {
  type = bool
  default = false
}
