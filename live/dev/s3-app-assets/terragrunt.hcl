include "root" {
  path = find_in_parent_folders()
}

dependency "lambda_image_processor" {
  config_path = "../lambda-image-processor"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    function_arn = "arn:aws:lambda:ap-south-1:000000000000:function:placeholder"
    execution_role_arn = "arn:aws:iam::000000000000:role/placeholder"
  }
}

terraform {
  source = "${get_repo_root()}/modules//s3"
}

inputs = {
  name                   = "app-assets"
  bucket_type            = "standard"
  versioning             = true
  lifecycle_enabled      = true
  intelligent_tiering    = true
  expiry_days            = 0
  encryption             = "AES256"
  kms_key_arn            = ""
  access_log_bucket_name = ""
  lambda_trigger_enabled    = true
  lambda_function_arn       = dependency.lambda_image_processor.outputs.function_arn
  lambda_execution_role_arn = dependency.lambda_image_processor.outputs.execution_role_arn
  lambda_trigger_events     = ["s3:ObjectCreated:*"]
  lambda_filter_prefix      = "uploads/"
  lambda_filter_suffix      = ".jpg" 
  extra_tags = {
    DataClassification = "internal"
  }
}
