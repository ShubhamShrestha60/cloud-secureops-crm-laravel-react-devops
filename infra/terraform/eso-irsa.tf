# External Secrets Operator IRSA: allow ESO pods to read Secrets Manager.
# ClusterSecretStore argocd/clustersecretstore.yaml uses
# jwt.serviceAccountRef {name: external-secrets, namespace: external-secrets},
# so that SA must be annotated with this role ARN (wired in addons.tf).

module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.8"

  role_name = "${var.project}-${var.env}-eso"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role_policy" "eso_secretsmanager" {
  name = "secretsmanager-read"
  role = module.eso_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/staging/*",
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/prod/*"
        ]
      }
    ]
  })
}

data "aws_caller_identity" "current" {}
