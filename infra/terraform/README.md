# Terraform — SecureOps EKS stack

## Prereqs

- AWS account + `aws login` (SSO preferred, no static keys in repo)
- S3 bucket + DynamoDB table for state (see `backend.tf` comments)
- `terraform >= 1.6`, `aws cli >= 2`, `helm >= 3.14`, `kubectl`

## First apply (staging)

```bash
terraform init
terraform plan -var-file=staging.tfvars -var github_repo=OWNER/REPO
terraform apply -var-file=staging.tfvars -var github_repo=OWNER/REPO
```

Copy outputs:

- `ecr_backend_url` / `ecr_frontend_url` -> Helm `values-*.yaml` image.repository
- `github_release_role_arn` -> GHA repo Variable `AWS_ROLE_TO_ASSUME`
- `rds_endpoint` for debugging (app reads it from Secrets Manager, not tfvars)

Then:

```bash
aws eks update-kubeconfig --name secureops-staging --region ap-south-1
kubectl get nodes
bash ../../argocd/bootstrap.sh
```

## Prod

```bash
terraform workspace new prod  # or separate state key per backend.hcl
terraform apply -var-file=prod.tfvars -var github_repo=OWNER/REPO
```

Prod differences (`prod.tfvars`): 3 AZs, `db.t3.small`, `multi_az=true`,
7-day backups, deletion protection, External Secrets enforced
(`secrets.create=false` in `values-prod.yaml`).

## Cost control

Staging uses 2 AZs, single NAT, `db.t3.micro`, 1-day backups.
Tear down dev clusters with `terraform destroy -var-file=staging.tfvars` when idle.
