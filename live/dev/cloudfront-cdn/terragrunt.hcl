include "root" {
  path = find_in_parent_folders()
}

dependency "s3_app_assets" {
  config_path = "../s3-app-assets"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    bucket_domain_name = "placeholder.s3.ap-south-1.amazonaws.com"
    bucket_name = "placeholder-bucket"
  }
}

terraform {
  source = "${get_repo_root()}/modules//cloudfront"
}

inputs = {
  cf_name                = "cdn"
  price_class            = "PriceClass_All"
  waf_enabled            = false
  waf_create             = false
  waf_web_acl_id         = ""
  waf_rate_limit_enabled = false
  waf_rate_limit         = 2000
  cache_enabled          = true
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["GET", "HEAD"]
  cached_methods         = ["GET", "HEAD"]
  forward_query_strings  = false
  forward_cookies        = "none"
  logging_enabled        = false
  logging_bucket_name    = ""
  geo_restriction_type      = "none"
  geo_restriction_locations = []
  acm_certificate_arn    = ""
  origins = [
    {
      domain_name    = "${dependency.s3_app_assets.outputs.bucket_domain_name}"
      origin_id      = "s3-assets"
      origin_type    = "s3"
      origin_path    = ""
      custom_headers = []
    },
  ]
  cache_behaviors = []
  extra_tags = {
    Component = "cdn"
  }
}
