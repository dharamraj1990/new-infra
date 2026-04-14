# modules/sqs/main.tf

locals {
  queue_name = var.fifo ? "${var.name_prefix}-${var.aws_region}-${var.project_name}-sqs-${var.name}.fifo" : "${var.name_prefix}-${var.aws_region}-${var.project_name}-sqs-${var.name}"
  dlq_name   = var.fifo ? "${var.name_prefix}-${var.aws_region}-${var.project_name}-sqs-${var.name}-dlq.fifo" : "${var.name_prefix}-${var.aws_region}-${var.project_name}-sqs-${var.name}-dlq"
  tags       = merge(var.common_tags, var.extra_tags, { Name = local.queue_name, Module = "sqs" })
}

# ── Dead Letter Queue ─────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  count = var.dlq_enabled ? 1 : 0
  name  = local.dlq_name

  fifo_queue                        = var.fifo
  content_based_deduplication       = var.fifo ? var.content_based_deduplication : false
  deduplication_scope               = var.fifo && var.high_throughput_fifo ? "messageGroup" : null
  fifo_throughput_limit             = var.fifo && var.high_throughput_fifo ? "perMessageGroupId" : null
  message_retention_seconds         = var.dlq_message_retention
  sqs_managed_sse_enabled           = var.kms_key_arn == "" ? var.sqs_managed_sse_enabled : false
  kms_master_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = merge(local.tags, { Name = local.dlq_name, Role = "dlq" })
}

# ── Main Queue ────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "this" {
  name = local.queue_name

  # FIFO settings
  fifo_queue                        = var.fifo
  content_based_deduplication       = var.fifo ? var.content_based_deduplication : false
  # High-throughput FIFO: set deduplication_scope + fifo_throughput_limit
  deduplication_scope               = var.fifo && var.high_throughput_fifo ? "messageGroup" : null
  fifo_throughput_limit             = var.fifo && var.high_throughput_fifo ? "perMessageGroupId" : null

  # Standard queue settings
  visibility_timeout_seconds  = var.visibility_timeout
  message_retention_seconds   = var.message_retention
  max_message_size            = var.max_message_size
  delay_seconds               = var.delay_seconds
  receive_wait_time_seconds   = var.receive_wait_time_seconds

  # Encryption — KMS takes priority, then SSE-SQS, then none
  sqs_managed_sse_enabled           = var.kms_key_arn == "" ? var.sqs_managed_sse_enabled : false
  kms_master_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = var.kms_key_arn != "" ? var.kms_data_key_reuse_period : null

  # DLQ redrive — JSON string attribute, NOT a block
  redrive_policy = var.dlq_enabled ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.dlq_max_receive_count
  }) : null

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !var.high_throughput_fifo || var.fifo
      error_message = "high_throughput_fifo requires fifo=true."
    }
  }
}

# ── Queue Policy ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "sqs_policy" {
  statement {
    sid    = "AllowAccountAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    # Explicit actions — not sqs:*
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
      "sqs:PurgeQueue",
    ]
    resources = [aws_sqs_queue.this.arn]
  }

  # Allow SNS topics to send to this queue (for SNS→SQS fanout).
  # ArnEquals is stricter than ArnLike — no wildcard pattern matching allowed.
  dynamic "statement" {
    for_each = length(var.allowed_sns_topic_arns) > 0 ? [1] : []
    content {
      sid    = "AllowSNSSend"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["sns.amazonaws.com"]
      }
      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.this.arn]
      condition {
        test     = "ArnEquals"   # strict — no wildcard matching
        variable = "aws:SourceArn"
        values   = var.allowed_sns_topic_arns
      }
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  queue_url = aws_sqs_queue.this.id
  policy    = data.aws_iam_policy_document.sqs_policy.json
}

# ── DLQ Policy ────────────────────────────────────────────────────────────────
# The DLQ needs its own queue policy to allow the main queue to redrive messages
# and allow operators to read/purge failed messages for debugging.
data "aws_iam_policy_document" "dlq_policy" {
  count = var.dlq_enabled ? 1 : 0

  statement {
    sid    = "AllowAccountAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:PurgeQueue",
    ]
    resources = [aws_sqs_queue.dlq[0].arn]
  }

  # Allow the main queue to redrive messages into the DLQ
  statement {
    sid    = "AllowRedriveFromMainQueue"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq[0].arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sqs_queue.this.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  count     = var.dlq_enabled ? 1 : 0
  queue_url = aws_sqs_queue.dlq[0].id
  policy    = data.aws_iam_policy_document.dlq_policy[0].json
}
