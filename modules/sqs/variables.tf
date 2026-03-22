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


# ── FIFO ──────────────────────────────────────────────────────────────────────
variable "fifo" {
  type        = bool
  default     = false
  description = "Create a FIFO queue (name will have .fifo suffix)"
}

variable "content_based_deduplication" {
  type        = bool
  default     = false
  description = "FIFO only: enable content-based deduplication (SHA-256 hash of body)"
}

variable "high_throughput_fifo" {
  type        = bool
  default     = false
  description = "FIFO only: enable high-throughput mode (deduplication_scope=messageGroup, 3000 msg/s per group)"
}

# ── Standard settings ─────────────────────────────────────────────────────────
variable "visibility_timeout" {
  type        = number
  default     = 30
  description = "Seconds a message is hidden after being received (0–43200)"
}

variable "message_retention" {
  type        = number
  default     = 86400
  description = "Seconds messages are retained (60–1209600). Default 1 day."
}

variable "max_message_size" {
  type        = number
  default     = 262144
  description = "Max message size in bytes (1024–262144). Default 256KB."
}

variable "delay_seconds" {
  type        = number
  default     = 0
  description = "Seconds to delay delivery of new messages (0–900)"
}

variable "receive_wait_time_seconds" {
  type        = number
  default     = 0
  description = "Long polling: seconds to wait for messages (0–20). 0 = short poll."
}

# ── DLQ ───────────────────────────────────────────────────────────────────────
variable "dlq_enabled" {
  type    = bool
  default = false
}

variable "dlq_max_receive_count" {
  type        = number
  default     = 3
  description = "Number of receives before moving message to DLQ"
}

variable "dlq_message_retention" {
  type        = number
  default     = 1209600
  description = "Seconds to retain messages in DLQ. Default 14 days."
}

# ── Encryption ────────────────────────────────────────────────────────────────
variable "sqs_managed_sse_enabled" {
  type        = bool
  default     = true
  description = "Enable SQS-managed server-side encryption (SSE-SQS). Ignored when kms_key_arn is set."
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "kms_data_key_reuse_period" {
  type        = number
  default     = 300
  description = "Seconds to reuse a KMS data key (60–86400)"
}

# ── Policy ────────────────────────────────────────────────────────────────────
variable "allowed_sns_topic_arns" {
  type        = list(string)
  default     = []
  description = "SNS topic ARNs allowed to send messages to this queue (SNS→SQS fanout)"
}
