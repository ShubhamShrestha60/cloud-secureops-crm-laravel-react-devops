variable "project" {
  description = "Resource name prefix."
  type        = string
  default     = "secureops"
}

variable "env" {
  description = "staging | prod. Used in names + tags."
  type        = string
  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be staging or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs (2 = cheap, 3 = prod HA)."
  type        = number
  default     = 3
}

variable "eks_version" {
  description = "EKS control-plane version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro for staging, db.t3.small+ for prod."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "secureops"
}

variable "db_username" {
  type    = string
  default = "secureops"
}

variable "domain_name" {
  description = "Public domain for the app (Route53 + ACM). Empty = skip DNS/ACM, use ALB hostname."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo allowed to push to ECR via OIDC, e.g. myorg/secureopsCRM_laravel-react_devops."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications. Empty = topic only, no subscription."
  type        = string
  default     = ""
}
