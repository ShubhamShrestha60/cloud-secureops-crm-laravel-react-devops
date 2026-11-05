output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer" {
  value = module.eks.cluster_oidc_issuer_url
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "github_release_role_arn" {
  value       = try(aws_iam_role.github_release[0].arn, null)
  description = "Copy into GHA repo Variable AWS_ROLE_TO_ASSUME. Null when var.github_repo is empty."
}
