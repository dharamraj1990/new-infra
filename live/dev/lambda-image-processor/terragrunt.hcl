include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//lambda"
}

inputs = {
  name                = "image-processor"
  package_type        = "zip"
  runtime             = "python3.12"
  handler             = "handler.main"
  arch                = "arm64"
  timeout             = 30
  memory_size         = 512
  log_retention_days  = 14
  iam_role_create     = true
  vpc_enabled         = false
  service_access      = ["s3", "ssm"]
  permission_boundary = ""
  environment_variables = {
    LOG_LEVEL = "INFO"
  }


  extra_tags = {
    Component = "image-processing"
  }
}
