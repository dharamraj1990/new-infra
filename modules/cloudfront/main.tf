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
  # checkov:skip=CKV2_AWS_31:WAF logging is configured in aws_wafv2_web_acl_logging_configuration below.
  # checkov:skip=CKV2_AWS_47:AWSManagedRulesKnownBadInputsRuleSet (which covers Log4j) is included in the default waf_managed_rules variable. Checkov cannot resolve dynamic for_each blocks in managed_rule_group_statement.
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

# ── WAF Logging ──────────────────────────────────────────────────────────────
# CloudWatch log group for WAF — name must start with "aws-waf-logs-"
resource "aws_cloudwatch_log_group" "waf" {
  # checkov:skip=CKV_AWS_158:WAF access logs are operational data, not sensitive. KMS encryption adds cost with minimal security benefit for log metadata.
  # checkov:skip=CKV_AWS_338:WAF logs require shorter retention than application logs. 90 days is sufficient for security investigations.
  count             = var.waf_enabled && var.waf_create ? 1 : 0
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = 90
  tags              = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.waf_enabled && var.waf_create ? 1 : 0
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Redact sensitive headers from WAF logs — Authorization and Cookie contain credentials
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    single_header { name = "cookie" }
  }
}

locals {
  # Use provided WAF ACL ID, or the one we just created
  waf_acl_id = (
    var.waf_enabled
    ? (var.waf_create ? aws_wafv2_web_acl.this[0].arn : var.waf_web_acl_id)
    : null
  )
}

# ── Security Response Headers Policy ─────────────────────────────────────────
# Adds OWASP-recommended HTTP security headers to every CloudFront response.
# These headers instruct browsers to enforce transport security, prevent
# clickjacking, block MIME-sniffing, and control referrer information.
resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.us_east_1
  name     = "${local.name}-security-headers"

  security_headers_config {
    # HSTS — force HTTPS for 2 years, include subdomains, preload-eligible
    strict_transport_security {
      access_control_max_age_sec = 63072000  # 2 years
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    # Prevent MIME-type sniffing (blocks drive-by download attacks)
    content_type_options {
      override = true
    }

    # Clickjacking protection — deny framing from any origin
    frame_options {
      frame_option = "DENY"
      override     = true
    }

    # Referrer policy — leak no path info cross-origin
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    # XSS auditor hint for legacy browsers
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }

  # Custom headers — Content-Security-Policy cannot be set in security_headers_config
  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), payment=()"
      override = true
    }
  }
}

# ── CloudFront Distribution ───────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "this" {
  # checkov:skip=CKV_AWS_174:TLSv1.2_2021 is enforced when acm_certificate_arn is provided. The CloudFront default certificate is only used during initial setup before a custom domain is configured — set acm_certificate_arn in input.yaml for production.
  # checkov:skip=CKV2_AWS_42:Custom SSL certificate is configured via acm_certificate_arn variable. Set it in input.yaml for production. Default certificate is intentionally allowed for pre-production use.
  # checkov:skip=CKV_AWS_310:Origin failover requires a secondary origin to be defined. This is an architectural decision — configure origins with failover pairs in input.yaml when high availability is required.
  # checkov:skip=CKV_AWS_374:Geo restriction is configurable via geo_restriction_type and geo_restriction_locations variables. Default is 'none' to support global deployments.
  # checkov:skip=CKV2_AWS_47:AWSManagedRulesKnownBadInputsRuleSet (Log4j protection) is in the default waf_managed_rules. Checkov cannot resolve dynamic for_each blocks referencing managed rule groups.
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

    # Security headers applied to every response from this distribution
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

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

  # Return friendly pages for 403/404 from S3 origins instead of leaking XML error responses
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
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

      response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

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
