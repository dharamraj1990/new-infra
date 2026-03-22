# modules/sns/main.tf
locals {
  topic_name = var.fifo ? "${var.name_prefix}-${var.aws_region}-${var.project_name}-sns-${var.name}.fifo" : "${var.name_prefix}-${var.aws_region}-${var.project_name}-sns-${var.name}"
  tags = merge(var.common_tags, var.extra_tags, { Name = local.topic_name, Module = "sns" })
}

resource "aws_sns_topic" "this" {
  name                        = local.topic_name
  display_name                = var.display_name
  fifo_topic                  = var.fifo
  content_based_deduplication = var.fifo ? var.content_based_deduplication : false
  kms_master_key_id           = var.kms_key_arn != "" ? var.kms_key_arn : null
  tags                        = local.tags
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "sns_policy" {
  statement {
    sid     = "AllowPublish"
    effect  = "Allow"
    principals {
      type        = "AWS"
      identifiers = length(var.allowed_role_arns) > 0 ? var.allowed_role_arns : ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["sns:Publish", "sns:Subscribe"]
    resources = [aws_sns_topic.this.arn]
  }
}

resource "aws_sns_topic_policy" "this" {
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.sns_policy.json
}

resource "aws_sns_topic_subscription" "this" {
  for_each  = { for i, s in var.subscriptions : "${s.protocol}-${i}" => s }
  topic_arn = aws_sns_topic.this.arn
  protocol  = each.value.protocol
  endpoint  = each.value.endpoint
}
