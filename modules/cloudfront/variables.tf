variable "cf_name"      { type = string }
variable "environment"  { type = string }
variable "name_prefix" {
  type        = string
  description = "Short prefix for all resource names derived from account (e.g. stg, prd, dev)"
}

variable "aws_region"   { type = string }
variable "project_name" { type = string }
variable "common_tags" {
  type    = map(string)
  default = {}
}
variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Per-resource extra tags merged on top of common_tags"
}


variable "origins" {
  description = "List of origins"
  type = list(object({
    domain_name    = string
    origin_id      = string
    origin_type    = string  # s3 | alb | custom
    origin_path    = string
    custom_headers = optional(list(object({ name = string, value = string })), [])
  }))
}

# ── WAF ───────────────────────────────────────────────────────────────────────
variable "waf_enabled" {
  type        = bool
  default     = false
  description = "Attach a WAF Web ACL to this distribution"
}

variable "waf_create" {
  type        = bool
  default     = false
  description = "Create a new WAF ACL (requires waf_enabled=true). Set false to use existing waf_web_acl_id."
}

variable "waf_web_acl_id" {
  type        = string
  default     = ""
  description = "ARN of an existing WAF Web ACL (when waf_enabled=true and waf_create=false)"
}

variable "waf_managed_rules" {
  description = "List of AWS Managed Rule Groups to attach"
  type = list(object({
    name                = string
    priority            = number
    managed_rule_group  = string
    override_action     = string            # none | count
    count_rules         = optional(list(string), [])
  }))
  default = [
    {
      name               = "CommonRuleSet"
      priority           = 1
      managed_rule_group = "AWSManagedRulesCommonRuleSet"
      override_action    = "none"
      count_rules        = []
    },
    {
      name               = "KnownBadInputs"
      priority           = 2
      managed_rule_group = "AWSManagedRulesKnownBadInputsRuleSet"
      override_action    = "none"
      count_rules        = []
    },
  ]
}

variable "waf_rate_limit_enabled" {
  type        = bool
  default     = false
  description = "Add a rate-based rule to block IPs exceeding waf_rate_limit requests per 5 min"
}

variable "waf_rate_limit" {
  type        = number
  default     = 2000
  description = "Max requests per 5 minutes per IP before blocking"
}

# ── Cache ─────────────────────────────────────────────────────────────────────
variable "cache_enabled" {
  type    = bool
  default = true
}

variable "min_ttl" {
  type    = number
  default = 0
}
variable "default_ttl" {
  type    = number
  default = 86400
}
variable "max_ttl" {
  type    = number
  default = 31536000
}

variable "forward_query_strings" {
  type    = bool
  default = false
}

variable "forward_headers" {
  type    = list(string)
  default = []
}

variable "forward_cookies" {
  type    = string
  default = "none"  # none | all | whitelist
}

variable "whitelisted_cookie_names" {
  type    = list(string)
  default = []
}

variable "cache_behaviors" {
  description = "Additional ordered cache behaviours by path pattern"
  type = list(object({
    path_pattern           = string
    origin_id              = string
    viewer_protocol_policy = string
    allowed_methods        = list(string)
    cached_methods         = list(string)
    forward_query_strings  = bool
    min_ttl                = number
    default_ttl            = number
    max_ttl                = number
  }))
  default = []
}

# ── Distribution ──────────────────────────────────────────────────────────────
variable "price_class" {
  type    = string
  default = "PriceClass_All"
}

variable "viewer_protocol_policy" {
  type    = string
  default = "redirect-to-https"
}

variable "allowed_methods" {
  type    = list(string)
  default = ["GET", "HEAD"]
}

variable "cached_methods" {
  type    = list(string)
  default = ["GET", "HEAD"]
}

variable "aliases" {
  type    = list(string)
  default = []
}

variable "default_root_object" {
  type    = string
  default = "index.html"
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "geo_restriction_type" {
  type    = string
  default = "none"  # none | whitelist | blacklist
}

variable "geo_restriction_locations" {
  type    = list(string)
  default = []
}

# ── Logging ───────────────────────────────────────────────────────────────────
variable "logging_enabled" {
  type    = bool
  default = false
}

variable "logging_bucket_name" {
  type    = string
  default = ""
}

variable "logging_include_cookies" {
  type    = bool
  default = false
}
