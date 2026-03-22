# modules/cloudfront/main.tf

locals {
  name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-cf-${var.cf_name}"
  tags = merge(var.common_tags, var.extra_tags, { Name = local.name, Module = "cloudfront" })
}

# ── Origin Access Control (one per S3 origin) ─────────────────────────────────
resource "aws_cloudfront_origin_access_control" "s3" {
  for_each = {
    for o in var.origins : o.origin_id => o if o.origin_type == "s3"
  }
  name                              = "${local.name}-${each.key}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── WAF Web ACL (optionally managed by this module) ───────────────────────────
# When waf_create = true, creates a managed-rule WAF ACL in us-east-1
# (CloudFront WAF must be in us-east-1 regardless of distribution region)
resource "aws_wafv2_web_acl" "this" {
  count    = var.waf_enabled && var.waf_create ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.name}-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.waf_managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.managed_rule_group
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.count_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.waf_rate_limit_enabled ? [1] : []
    content {
      name     = "RateLimitRule"
      priority = 100

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.waf_rate_limit
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

locals {
  # Use provided WAF ACL ID, or the one we just created
  waf_acl_id = (
    var.waf_enabled
    ? (var.waf_create ? aws_wafv2_web_acl.this[0].arn : var.waf_web_acl_id)
    : null
  )
}

# ── CloudFront Distribution ───────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name
  price_class         = var.price_class
  aliases             = var.aliases
  default_root_object = var.default_root_object
  web_acl_id          = local.waf_acl_id

  dynamic "origin" {
    for_each = var.origins
    content {
      domain_name = origin.value.domain_name
      origin_id   = origin.value.origin_id
      origin_path = origin.value.origin_path != "" ? origin.value.origin_path : null

      origin_access_control_id = (
        origin.value.origin_type == "s3"
        ? aws_cloudfront_origin_access_control.s3[origin.value.origin_id].id
        : null
      )

      dynamic "custom_origin_config" {
        for_each = origin.value.origin_type != "s3" ? [1] : []
        content {
          http_port              = 80
          https_port             = 443
          origin_protocol_policy = "https-only"
          origin_ssl_protocols   = ["TLSv1.2"]
        }
      }

      dynamic "custom_header" {
        for_each = origin.value.custom_headers
        content {
          name  = custom_header.value.name
          value = custom_header.value.value
        }
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = var.origins[0].origin_id
    viewer_protocol_policy = var.viewer_protocol_policy
    allowed_methods        = var.allowed_methods
    cached_methods         = var.cached_methods
    compress               = true

    forwarded_values {
      query_string = var.forward_query_strings
      headers      = var.forward_headers

      cookies {
        forward           = var.forward_cookies
        whitelisted_names = var.forward_cookies == "whitelist" ? var.whitelisted_cookie_names : null
      }
    }

    min_ttl     = var.min_ttl
    default_ttl = var.cache_enabled ? var.default_ttl : 0
    max_ttl     = var.cache_enabled ? var.max_ttl : 0
  }

  # Additional cache behaviours (path patterns)
  dynamic "ordered_cache_behavior" {
    for_each = var.cache_behaviors
    content {
      path_pattern           = ordered_cache_behavior.value.path_pattern
      target_origin_id       = ordered_cache_behavior.value.origin_id
      viewer_protocol_policy = ordered_cache_behavior.value.viewer_protocol_policy
      allowed_methods        = ordered_cache_behavior.value.allowed_methods
      cached_methods         = ordered_cache_behavior.value.cached_methods
      compress               = true

      forwarded_values {
        query_string = ordered_cache_behavior.value.forward_query_strings
        cookies {
          forward = "none"
        }
      }

      min_ttl     = ordered_cache_behavior.value.min_ttl
      default_ttl = ordered_cache_behavior.value.default_ttl
      max_ttl     = ordered_cache_behavior.value.max_ttl
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == ""
    acm_certificate_arn            = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.acm_certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  dynamic "logging_config" {
    for_each = var.logging_enabled && var.logging_bucket_name != "" ? [1] : []
    content {
      include_cookies = var.logging_include_cookies
      bucket          = "${var.logging_bucket_name}.s3.amazonaws.com"
      prefix          = "cloudfront/${local.name}/"
    }
  }

  tags = local.tags
}
