variable "name" {
  type        = string
  description = "Resource name suffix"
}

variable "environment" {
  type        = string
  description = "Environment name e.g. dev, stg, prod"
}
variable "name_prefix" {
  type        = string
  description = "Short prefix for all resource names derived from account (e.g. stg, prd, dev)"
}


variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "project_name" {
  type        = string
  description = "Project name"
}

variable "common_tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources"
}
variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Per-resource extra tags merged on top of common_tags"
}

# ── Monitoring integrations ───────────────────────────────────────────────────
variable "prometheus_monitoring" {
  type        = bool
  default     = false
  description = "Tag instance for Prometheus scraping (PrometheusMonitoring = true/false)"
}

variable "argus_monitoring" {
  type        = bool
  default     = false
  description = "Tag instance for Argus monitoring (ArgusMonitoring = true/false)"
}


# ── AMI / Architecture ────────────────────────────────────────────────────────
variable "arch" {
  type        = string
  default     = "arm64"
  description = "CPU architecture: arm64 or x86_64"
}

variable "os" {
  type        = string
  default     = "ubuntu"
  description = "OS: ubuntu or amazon_linux"
}

variable "instance_type" {
  type        = string
  default     = "t4g.small"
  description = "EC2 instance type"
}

variable "ami" {
  type        = string
  default     = "auto"
  description = "AMI ID or 'auto' to use the latest for the selected OS + arch"
}

# ── Key pair ──────────────────────────────────────────────────────────────────
variable "key_pair_create" {
  type        = bool
  default     = true
  description = "Create a new key pair and store PEM in Secrets Manager"
}

variable "existing_key_pair_name" {
  type        = string
  default     = ""
  description = "Name of an existing key pair to use (when key_pair_create = false)"
}

# ── Security group ────────────────────────────────────────────────────────────
variable "sg_create" {
  type        = bool
  default     = true
  description = "Create a new security group"
}

variable "existing_sg_ids" {
  type        = list(string)
  default     = []
  description = "IDs of existing security groups to attach"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the security group — required, do not use default VPC"

  validation {
    condition     = var.vpc_id != ""
    error_message = "vpc_id is required. Do not deploy EC2 into the default VPC."
  }
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the instance — required for standalone instances"

  validation {
    condition     = var.subnet_id != ""
    error_message = "subnet_id is required. Specify the subnet for the instance."
  }
}

variable "ingress_rules" {
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default     = []
  description = "List of ingress rules for the security group"
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
variable "asg_enabled" {
  type        = bool
  default     = false
  description = "Create an ASG instead of a standalone instance"
}

variable "asg_desired" {
  type        = number
  default     = 1
  description = "ASG desired capacity"
}

variable "asg_min" {
  type        = number
  default     = 1
  description = "ASG minimum capacity"
}

variable "asg_max" {
  type        = number
  default     = 3
  description = "ASG maximum capacity"
}

variable "asg_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Subnet IDs for ASG instances"
}

# ── EBS ───────────────────────────────────────────────────────────────────────
variable "ebs_encryption" {
  type        = string
  default     = "default"
  description = "EBS encryption: 'default' (AWS managed) or 'kms' (customer managed)"
}

variable "ebs_kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN for EBS encryption (required when ebs_encryption = kms)"
}

variable "ebs_volumes" {
  type = list(object({
    device_name = string
    size        = number
    type        = string
  }))
  default = [
    {
      device_name = "/dev/xvda"
      size        = 30
      type        = "gp3"
    }
  ]
  description = "EBS volumes to attach. Each entry requires device_name, size (GB), and type (gp3, gp2, io1 etc.)"
}

# ── IAM ───────────────────────────────────────────────────────────────────────
variable "iam_role_create" {
  type        = bool
  default     = true
  description = "Create a new IAM role and instance profile"
}

variable "iam_role_name" {
  type        = string
  default     = ""
  description = "Name for the IAM role (auto-generated when empty)"
}

variable "existing_instance_profile" {
  type        = string
  default     = ""
  description = "Name of existing instance profile (when iam_role_create = false)"
}

# ── Metadata / misc ───────────────────────────────────────────────────────────
variable "imdsv2_enabled" {
  type        = bool
  default     = true
  description = "Enforce IMDSv2 (http_tokens = required)"
}

variable "user_data" {
  type        = string
  default     = ""
  description = "User data script (plain text, base64-encoded automatically)"
}
