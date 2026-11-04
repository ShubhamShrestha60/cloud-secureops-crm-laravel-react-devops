# Command Index

Every command that matters, grouped by task. Labels:

- `READ-ONLY` — safe to run, no state change.
- `STATE-CHANGING` — creates/updates resources or config.
- `DESTRUCTIVE` — deletes data or infrastructure.

## Identity and clock

| Command | Label | Notes |
|---|---|---|
| `aws sts get-caller-identity` | READ-ONLY | confirms account/role |
| `date -u` | READ-ONLY | compare with AWS; skew >5 min breaks SigV4 |
| `sudo chronyc -a makestep` | STATE-CHANGING | fix host clock drift |
| `aws configure list` | READ-ONLY | shows credential source/region |

## Terraform

| Command | Label | Notes |
|---|---|---|
| `terraform init` | STATE-CHANGING | configures S3/DynamoDB backend |
| `terraform fmt -check -recursive` | READ-ONLY | formatting gate |
| `terraform validate` | READ-ONLY | syntax/module validation |
| `terraform plan -var-file=staging.tfvars` | READ-ONLY | preview |
| `terraform apply -var-file=staging.tfvars` | STATE-CHANGING | create/update |
| `terraform plan -destroy -var-file=staging.tfvars` | READ-ONLY | preview deletion |
| `terraform destroy -var-file=staging.tfvars` | DESTRUCTIVE | delete all managed resources |
| `terraform output` | READ-ONLY | endpoint/ARN values |
| `terraform state list` | READ-ONLY | inventory |
| `terraform force-unlock <ID>` | STATE-CHANGING | only when no run is active |

## Kubernetes access

| Command | Label | Notes |
|---|---|---|
| `aws eks update-kubeconfig --name secureops-staging --region ap-south-1` | STATE-CHANGING | writes kubeconfig |
| `kubectl cluster-info` | READ-ONLY | API reachability |
| `kubectl get nodes -o wide` | READ-ONLY | node readiness |
| `kubectl -n secureops-staging get pods -o wide` | READ-ONLY | workload state |
| `kubectl -n secureops-staging get events --sort-by=.lastTimestamp` | READ-ONLY | first diagnostic |
| `kubectl -n secureops-staging describe pod <pod>` | READ-ONLY | scheduling/probe/secret errors |
| `kubectl -n secureops-staging logs deploy/<name> --tail=100` | READ-ONLY | app logs |
| `kubectl -n secureops-staging logs -f deploy/<name>` | READ-ONLY | follow logs |
| `kubectl -n secureops-staging get ingress,svc,hpa,pdb,job` | READ-ONLY | edge/scaling state |
| `kubectl top nodes` / `kubectl top pods -n secureops-staging` | READ-ONLY | requires metrics-server |
| `kubectl -n secureops-staging rollout history deploy/<name>` | READ-ONLY | revisions |
| `kubectl -n secureops-staging rollout undo deploy/<name>` | STATE-CHANGING | ArgoCD may revert |
| `kubectl -n secureops-staging rollout restart deploy/<name>` | STATE-CHANGING | picks up new env |
| `kubectl -n secureops-staging delete pod <pod>` | STATE-CHANGING | recreated by controller |

## Helm

| Command | Label | Notes |
|---|---|---|
| `helm lint charts/secureops -f charts/secureops/values-staging.yaml` | READ-ONLY | chart sanity |
| `helm template secureops charts/secureops -f charts/secureops/values-staging.yaml` | READ-ONLY | render manifests |
| `helm upgrade --install ... --dry-run=server` | READ-ONLY | API-server validation |
| `helm upgrade --install secureops charts/secureops -f charts/secureops/values-staging.yaml -n secureops-staging` | STATE-CHANGING | manual install (ArgoCD is normal path) |
| `helm uninstall secureops -n secureops-staging` | DESTRUCTIVE | removes release resources |

## ArgoCD

| Command | Label | Notes |
|---|---|---|
| `./argocd/bootstrap.sh` | STATE-CHANGING | install ArgoCD + project + app |
| `kubectl apply --server-side -n argocd -f <install.yaml>` | STATE-CHANGING | avoids CRD annotation limit |
| `kubectl -n argocd get applications` | READ-ONLY | sync/health |
| `kubectl -n argocd get application secureops-staging -o yaml` | READ-ONLY | full status |
| `kubectl -n argocd patch application secureops-staging --type merge -p '{"operation":{"sync":{}}}'` | STATE-CHANGING | force sync |
| `kubectl -n argocd delete application secureops-staging --cascade=foreground` | DESTRUCTIVE | stops GitOps ownership |

## Images

| Command | Label | Notes |
|---|---|---|
| `docker build -t secureops-backend:local ./backend` | READ-ONLY | local build |
| `docker build -t secureops-frontend:local ./frontend` | READ-ONLY | local build |
| `aws ecr get-login-password --region ap-south-1 \| docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com` | STATE-CHANGING | docker auth |
| `docker push <ECR_URL>:sha-<12>` | STATE-CHANGING | push immutable tag |
| `aws ecr describe-images --repository-name secureops-staging-backend --region ap-south-1` | READ-ONLY | tags/scans |
| `aws ecr describe-repositories --region ap-south-1` | READ-ONLY | repos/settings |

## Database

| Command | Label | Notes |
|---|---|---|
| `aws rds describe-db-instances --db-instance-identifier secureops-staging --region ap-south-1` | READ-ONLY | status/endpoint |
| `kubectl -n secureops-staging exec deploy/secureops-staging-backend -- php artisan migrate:status` | READ-ONLY | schema state |
| `kubectl -n secureops-staging exec deploy/secureops-staging-backend -- php artisan db:seed --force` | STATE-CHANGING | creates admin |
| `aws rds create-db-snapshot ...` | STATE-CHANGING | manual backup |
| `aws rds restore-db-instance-from-db-snapshot ...` | STATE-CHANGING | restore drill |
| `aws rds stop-db-instance --db-instance-identifier secureops-staging --region ap-south-1` | STATE-CHANGING | 7-day auto-restart |
| `aws rds start-db-instance --db-instance-identifier secureops-staging --region ap-south-1` | STATE-CHANGING | wake |

## Power

| Command | Label | Notes |
|---|---|---|
| `./ops/sleep.sh --dry-run` | READ-ONLY | prints intent |
| `./ops/sleep.sh` | STATE-CHANGING | nodes→0, RDS stop |
| `./ops/wake.sh` | STATE-CHANGING | nodes→3, RDS start |
| `aws eks update-nodegroup-config --cluster-name secureops-staging --nodegroup-name <ng> --scaling-config minSize=0,maxSize=4,desiredSize=0 --region ap-south-1` | STATE-CHANGING | manual sleep |
| `aws eks update-nodegroup-config --cluster-name secureops-staging --nodegroup-name <ng> --scaling-config minSize=2,maxSize=4,desiredSize=3 --region ap-south-1` | STATE-CHANGING | manual wake |

## Edge

| Command | Label | Notes |
|---|---|---|
| `aws elbv2 describe-load-balancers --region ap-south-1` | READ-ONLY | ALB exists |
| `aws elbv2 describe-target-health --target-group-arn <TG_ARN> --region ap-south-1` | READ-ONLY | healthy targets |
| `aws elbv2 delete-listener --listener-arn <ARN> --region ap-south-1` | DESTRUCTIVE | manual ALB cleanup |
| `aws elbv2 delete-load-balancer --load-balancer-arn <ARN> --region ap-south-1` | DESTRUCTIVE | manual ALB cleanup |
| `aws elbv2 delete-target-group --target-group-arn <ARN> --region ap-south-1` | DESTRUCTIVE | manual TG cleanup |
| `aws acm request-certificate --domain-name <DOMAIN> --validation-method DNS --region ap-south-1` | STATE-CHANGING | cert request |
| `aws acm wait certificate-validated --certificate-arn <ARN> --region ap-south-1` | READ-ONLY | wait |
| `aws wafv2 get-web-acl-for-resource --resource-arn <ALB_ARN> --region ap-south-1` | READ-ONLY | WAF association |
| `dig +short <DOMAIN>` | READ-ONLY | DNS |

## Secrets

| Command | Label | Notes |
|---|---|---|
| `aws secretsmanager get-secret-value --secret-id secureops/staging/app --region ap-south-1 --query SecretString --output text` | READ-ONLY | do not log output |
| `kubectl -n secureops-staging get externalsecret` | READ-ONLY | sync state |
| `kubectl -n secureops-staging get secret` | READ-ONLY | names only |
| `kubectl -n argocd create secret generic repo-secureops ...` | STATE-CHANGING | ArgoCD repo auth |

## Cost and cleanup

| Command | Label | Notes |
|---|---|---|
| `aws budgets describe-budgets --account-id <ACCOUNT_ID>` | READ-ONLY | budget state |
| `aws ce get-cost-and-usage ...` | READ-ONLY | spend by service |
| `aws ec2 describe-addresses --region ap-south-1` | READ-ONLY | orphan EIPs |
| `aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available` | READ-ONLY | orphan NAT |
| `aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available` | READ-ONLY | orphan EBS |
| `aws logs describe-log-groups --region ap-south-1` | READ-ONLY | log retention |
| `aws dynamodb delete-table --table-name secureops-terraform-locks --region ap-south-1` | DESTRUCTIVE | after destroy |
| `aws s3api delete-bucket --bucket <state-bucket> --region ap-south-1` | DESTRUCTIVE | last step |

## Git

| Command | Label | Notes |
|---|---|---|
| `ssh -T git@github.com` | READ-ONLY | auth check |
| `git status && git diff` | READ-ONLY | before commit |
| `git log --oneline -10` | READ-ONLY | history |
| `git show HEAD:docker-compose.yml` | READ-ONLY | committed version |
| `git push origin main` | STATE-CHANGING | publish |
