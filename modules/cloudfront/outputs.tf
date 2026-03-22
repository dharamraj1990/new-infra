output "distribution_id"          { value = aws_cloudfront_distribution.this.id }
output "distribution_arn"         { value = aws_cloudfront_distribution.this.arn }
output "distribution_domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "distribution_hosted_zone_id" { value = aws_cloudfront_distribution.this.hosted_zone_id }
output "oac_ids"                  { value = { for k, v in aws_cloudfront_origin_access_control.s3 : k => v.id } }
output "waf_acl_arn"              { value = local.waf_acl_id != null ? local.waf_acl_id : "" }
