# modules/lambda/main.tf
#
# KEY FIXES vs previous version:
#  1. package_type must be "Zip" or "Image" (capital first letter) — not "zip"/"container"
#  2. filename/image_uri cannot be conditional nulls in a single resource —
#     split into two separate resource blocks (aws_lambda_function.zip and .image)
#     only one is created based on package_type
#  3. placeholder.zip bundled in module directory so zip lambdas without a
#     real filename still plan/apply successfully
#  4. All trigger permissions reference the created function correctly

locals {
  function_name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-lambda-${var.name}"
  role_name     = var.iam_role_name != "" ? var.iam_role_name : "${local.function_name}-role"
  is_zip        = var.package_type != "container"   # "zip" or anything else = Zip

  tags = merge(var.common_tags, var.extra_tags, {
    Name   = local.function_name
    Module = "lambda"
  })
}

# ── IAM Role ─────────────────────────────────────────────────────────────────
resource "aws_iam_role" "this" {
  count = var.iam_role_create ? 1 : 0
  name  = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  permissions_boundary = var.permission_boundary != "" ? var.permission_boundary : null
  tags                 = local.tags
}

locals {
  execution_role_arn = var.iam_role_create ? aws_iam_role.this[0].arn : var.iam_role_arn
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  count      = var.iam_role_create ? 1 : 0
  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc_execution" {
  count      = var.iam_role_create && var.vpc_enabled ? 1 : 0
  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# X-Ray daemon write access — required for Active tracing
resource "aws_iam_role_policy_attachment" "xray" {
  count      = var.iam_role_create ? 1 : 0
  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── Service access policies ───────────────────────────────────────────────────
# Each policy is scoped to specific resource ARNs when provided.
# Falls back to ["*"] only when the ARN list is empty (explicit opt-in to wide access).
data "aws_iam_policy_document" "service_access" {
  count = var.iam_role_create && length(var.service_access) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = contains(var.service_access, "s3") ? [1] : []
    content {
      sid       = "S3Access"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      resources = length(var.s3_resource_arns) > 0 ? flatten([
        for arn in var.s3_resource_arns : [arn, "${arn}/*"]
      ]) : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "sqs") ? [1] : []
    content {
      sid       = "SQSAccess"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
      resources = length(var.sqs_resource_arns) > 0 ? var.sqs_resource_arns : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "sns") ? [1] : []
    content {
      sid       = "SNSAccess"
      actions   = ["sns:Publish", "sns:Subscribe", "sns:Unsubscribe"]
      resources = length(var.sns_resource_arns) > 0 ? var.sns_resource_arns : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "ssm") ? [1] : []
    content {
      sid       = "SSMAccess"
      actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = length(var.ssm_resource_arns) > 0 ? var.ssm_resource_arns : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "secretsmanager") ? [1] : []
    content {
      sid       = "SecretsAccess"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = length(var.secretsmanager_resource_arns) > 0 ? var.secretsmanager_resource_arns : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "dynamodb") ? [1] : []
    content {
      sid       = "DynamoDBAccess"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
      resources = length(var.dynamodb_resource_arns) > 0 ? var.dynamodb_resource_arns : ["*"]
    }
  }
  dynamic "statement" {
    for_each = contains(var.service_access, "ecr") ? [1] : []
    content {
      sid       = "ECRAccess"
      actions   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability", "ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "service_access" {
  count  = var.iam_role_create && length(var.service_access) > 0 ? 1 : 0
  name   = "${local.role_name}-svc-access"
  policy = data.aws_iam_policy_document.service_access[0].json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "service_access" {
  count      = var.iam_role_create && length(var.service_access) > 0 ? 1 : 0
  role       = aws_iam_role.this[0].name
  policy_arn = aws_iam_policy.service_access[0].arn
}

# ── Security Group (VPC only) ─────────────────────────────────────────────────
resource "aws_security_group" "this" {
  count  = var.vpc_enabled && var.sg_create ? 1 : 0
  name   = "${local.function_name}-sg"
  vpc_id = var.vpc_id

  lifecycle {
    precondition {
      condition     = var.vpc_id != ""
      error_message = "vpc_id is required when vpc_enabled=true."
    }
    precondition {
      condition     = length(var.subnet_ids) > 0
      error_message = "subnet_ids must have at least one subnet when vpc_enabled=true."
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.function_name}-sg" })
}

locals {
  sg_ids = var.vpc_enabled ? (
    var.sg_create
    ? concat([aws_security_group.this[0].id], var.existing_sg_ids)
    : var.existing_sg_ids
  ) : []
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ── Lambda ZIP ───────────────────────────────────────────────────────────────
# package_type must be "Zip" (capital Z) — AWS API rejects "zip"
resource "aws_lambda_function" "zip" {
  count = local.is_zip ? 1 : 0

  function_name                  = local.function_name
  role                           = local.execution_role_arn
  architectures                  = [var.arch]
  timeout                        = var.timeout
  memory_size                    = var.memory_size
  package_type                   = "Zip"
  runtime                        = var.runtime
  handler                        = var.handler
  reserved_concurrent_executions = var.reserved_concurrent_executions
  # filename is REQUIRED for Zip type — use provided path or bundled placeholder
  filename         = var.filename != null && var.filename != "" ? var.filename : "${path.module}/placeholder.zip"
  source_code_hash = var.source_code_hash != null ? var.source_code_hash : null

  # X-Ray active tracing — end-to-end distributed tracing across Lambda + downstream calls
  tracing_config {
    mode = var.tracing_mode
  }

  # DLQ for failed async invocations (event-driven failures that Lambda retried and gave up on)
  dynamic "dead_letter_config" {
    for_each = var.dlq_arn != "" ? [1] : []
    content {
      target_arn = var.dlq_arn
    }
  }

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []
    content { variables = var.environment_variables }
  }

  dynamic "vpc_config" {
    for_each = var.vpc_enabled ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = local.sg_ids
    }
  }

  tags = local.tags
  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachment.basic_execution,
    aws_iam_role_policy_attachment.xray,
  ]
}

# ── Lambda Container Image ────────────────────────────────────────────────────
# package_type must be "Image" (capital I) — AWS API rejects "container"
resource "aws_lambda_function" "image" {
  count = local.is_zip ? 0 : 1

  function_name                  = local.function_name
  role                           = local.execution_role_arn
  architectures                  = [var.arch]
  timeout                        = var.timeout
  memory_size                    = var.memory_size
  package_type                   = "Image"
  image_uri                      = var.image_uri   # REQUIRED for Image type
  reserved_concurrent_executions = var.reserved_concurrent_executions

  # X-Ray active tracing — end-to-end distributed tracing
  tracing_config {
    mode = var.tracing_mode
  }

  # DLQ for failed async invocations
  dynamic "dead_letter_config" {
    for_each = var.dlq_arn != "" ? [1] : []
    content {
      target_arn = var.dlq_arn
    }
  }

  dynamic "image_config" {
    for_each = (length(var.image_command) > 0 || length(var.image_entry_point) > 0) ? [1] : []
    content {
      command           = length(var.image_command) > 0 ? var.image_command : null
      entry_point       = length(var.image_entry_point) > 0 ? var.image_entry_point : null
      working_directory = var.image_working_directory
    }
  }

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []
    content { variables = var.environment_variables }
  }

  dynamic "vpc_config" {
    for_each = var.vpc_enabled ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = local.sg_ids
    }
  }

  tags = local.tags
  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachment.basic_execution,
    aws_iam_role_policy_attachment.xray,
  ]
}

# ── Unified locals for outputs and trigger resources ─────────────────────────
locals {
  fn_arn        = local.is_zip ? aws_lambda_function.zip[0].arn        : aws_lambda_function.image[0].arn
  fn_name       = local.is_zip ? aws_lambda_function.zip[0].function_name : aws_lambda_function.image[0].function_name
  fn_invoke_arn = local.is_zip ? aws_lambda_function.zip[0].invoke_arn : aws_lambda_function.image[0].invoke_arn
}

# ── SNS → Lambda trigger ──────────────────────────────────────────────────────
resource "aws_lambda_permission" "sns_invoke" {
  count         = var.sns_trigger_enabled && var.sns_topic_arn != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = local.fn_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}

resource "aws_sns_topic_subscription" "lambda_trigger" {
  count     = var.sns_trigger_enabled && var.sns_topic_arn != "" ? 1 : 0
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = local.fn_arn
}

# ── SQS → Lambda trigger ──────────────────────────────────────────────────────
resource "aws_lambda_permission" "sqs_invoke" {
  count         = var.sqs_trigger_enabled && var.sqs_queue_arn != "" ? 1 : 0
  statement_id  = "AllowSQSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = local.fn_name
  principal     = "sqs.amazonaws.com"
  source_arn    = var.sqs_queue_arn
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  count            = var.sqs_trigger_enabled && var.sqs_queue_arn != "" ? 1 : 0
  event_source_arn = var.sqs_queue_arn
  function_name    = local.fn_arn
  batch_size       = var.sqs_batch_size
  enabled          = true
}
