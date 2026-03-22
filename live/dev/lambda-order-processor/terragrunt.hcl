include "root" {
  path = find_in_parent_folders()
}

dependency "ecr_order_processor" {
  config_path = "../ecr-order-processor"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    repository_url = "000000000000.dkr.ecr.ap-south-1.amazonaws.com/placeholder"
  }
}

dependency "sqs_order_queue" {
  config_path = "../sqs-order-queue"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    queue_arn = "arn:aws:sqs:ap-south-1:000000000000:placeholder"
    queue_url = "https://sqs.ap-south-1.amazonaws.com/000000000000/placeholder"
  }
}

terraform {
  source = "${get_repo_root()}/modules//lambda"
}

inputs = {
  name                = "order-processor"
  package_type        = "container"
  runtime             = "python3.12"
  handler             = "handler.main"
  arch                = "arm64"
  timeout             = 60
  memory_size         = 1024
  log_retention_days  = 14
  iam_role_create     = true
  vpc_enabled         = false
  service_access      = ["sqs", "dynamodb"]
  permission_boundary = ""
  environment_variables = {
    LOG_LEVEL = "INFO"
  }

  image_uri = "${dependency.ecr_order_processor.outputs.repository_url}:latest"
  sqs_trigger_enabled = true
  sqs_queue_arn       = dependency.sqs_order_queue.outputs.queue_arn
  sqs_batch_size      = 10
  extra_tags = {
    Component = "order-processing"
  }
}
