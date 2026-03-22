include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//ecr"
}

inputs = {
  name                       = "order-processor"
  scan_on_push               = true
  tag_immutability           = true
  encryption                 = "AES256"
  max_image_count            = 10
  lambda_integration_enabled = true
  extra_tags = {
    Component = "order-processing"
  }
}
