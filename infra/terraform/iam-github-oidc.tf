# GitHub Actions OIDC -> ECR push without static AWS keys.
# Set var.github_repo = "OWNER/REPO". Leave empty to skip (e.g. first plan).
# After apply: copy role ARN into GHA repo Variable AWS_ROLE_TO_ASSUME.

data "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub OIDC thumbprints (2026): GitHub serves certs via Let's Encrypt
  # hierarchy (leaf <- YR2 intermediate <- Root YR, cross-signed by ISRG Root X1).
  # Keep the legacy thumbprint as well; AWS matches any entry in the list.
  thumbprint_list = [
    "ab9d0263244dd0326eb67015705a667e79cfe998", # Root YR cross-sign
    "cabd2a79a1076a31f21d253635cb039d4329a5e8", # ISRG Root X1
    "6938fd4d98bab03faadb97b34396831e3780aea1", # legacy GitHub/DigiCert
  ]
}

locals {
  github_oidc_arn = var.github_repo != "" ? try(data.aws_iam_openid_connect_provider.github[0].arn, aws_iam_openid_connect_provider.github[0].arn) : aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "github_release" {
  count = var.github_repo != "" ? 1 : 0
  name  = "${var.project}-${var.env}-github-release"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # NOTE: GitHub's sub format embeds numeric IDs:
        # repo:OWNER@ownerID/REPO@repoID:ref:... — the wildcards cover both
        # the legacy (no IDs) and current formats.
        StringLike = { "token.actions.githubusercontent.com:sub" = "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_release_ecr" {
  count = var.github_repo != "" ? 1 : 0
  name  = "ecr-push"
  role  = aws_iam_role.github_release[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.frontend.arn
        ]
      }
    ]
  })
}
