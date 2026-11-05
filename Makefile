.PHONY: up down build logs ps seed helm-lint tf-validate

up:
	docker compose up --build -d

down:
	docker compose down

build:
	docker compose build

logs:
	docker compose logs -f

ps:
	docker compose ps

seed:
	docker compose exec backend php artisan db:seed --force

helm-lint:
	helm lint charts/secureops -f charts/secureops/values-staging.yaml
	helm lint charts/secureops -f charts/secureops/values-prod.yaml
	helm template secureops charts/secureops -f charts/secureops/values-staging.yaml --namespace secureops-staging | kubeconform -strict -summary || true

tf-validate:
	terraform -chdir=infra/terraform init -backend=false
	terraform -chdir=infra/terraform validate
	terraform -chdir=infra/terraform fmt -check -recursive
