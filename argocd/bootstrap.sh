#!/bin/sh
set -eu
# Bootstrap ArgoCD + SecureOps apps on the EKS cluster from Terraform outputs.
# Run after: terraform apply -var-file=staging.tfvars && aws eks update-kubeconfig ...

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/apps/staging.yaml

echo "ArgoCD server: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Staging (sole live env) syncs automatically on push to main."
