include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//s3"
}

inputs = {
  name                   = "audit-logs"
  bucket_type            = "logging"
  versioning             = false
  lifecycle_enabled      = true
  intelligent_tiering    = false
  expiry_days            = 90
  encryption             = "AES256"
  kms_key_arn            = ""
  access_log_bucket_name = ""
  lambda_trigger_enabled = false
  extra_tags = {
    DataClassification = "restricted"
    Retention = "90days"
  }
}
