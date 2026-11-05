# WAFv2 in front of the ALB created by the AWS LB Controller.
# The ALB itself is controller-managed, so we look it up by cluster tag
# and associate. Default action ALLOW + managed deny rules (prod posture:
# block known-bad input, rate-limit brute force like /api/v1/login).

data "aws_lbs" "app" {
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
  }
}

locals {
  alb_arn    = one(data.aws_lbs.app.arns)
  alb_suffix = join("/", slice(split("/", one(data.aws_lbs.app.arns)), 1, 4))
}

resource "aws_wafv2_web_acl" "app" {
  name  = "${var.project}-${var.env}-app"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-badinputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "login-rate-limit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 3000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.env}-app"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project}-${var.env}-waf"
  }
}

resource "aws_wafv2_web_acl_association" "app" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.app.arn
}
