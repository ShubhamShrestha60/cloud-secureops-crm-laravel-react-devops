# 02 — Workstation Setup

**Goal:** install and verify every tool used by this project, then prove the
workstation can talk to AWS and GitHub.

**Time:** 20–40 minutes depending on downloads.
**Safety:** package installation is `STATE-CHANGING` on your workstation only.

The original workstation was AlmaLinux. Commands for RHEL/AlmaLinux are shown
first; Ubuntu/Debian equivalents are in the notes.

---

## 2.1 Base packages

### AlmaLinux / RHEL / Rocky

```bash
sudo dnf update -y
sudo dnf install -y git jq unzip curl wget openssl bind-utils tar
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y git jq unzip curl wget openssl dnsutils tar
```

Verify:

```bash
git --version
jq --version
curl --version | head -n1
```

---

## 2.2 AWS CLI v2

### AlmaLinux / RHEL / Ubuntu (x86_64)

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
aws --version
```

Expected: `aws-cli/2.x ...`. If you are on ARM, use
`awscli-exe-linux-aarch64.zip`.

Configure:

```bash
aws configure
# Access Key ID:     <from IAM>
# Secret Access Key: <from IAM>
# Default region:    ap-south-1
# Output format:     json
aws sts get-caller-identity
```

If the identity call fails with `Signature expired`, fix the clock:

```bash
sudo chronyc -a makestep
# or: sudo timedatectl set-ntp true
```

### Prefer SSO over long-lived keys

If your account supports IAM Identity Center, use `aws configure sso` instead of
static keys. Static keys are acceptable for a short learning build but must be
rotated and never committed.

---

## 2.3 Terraform

### AlmaLinux / RHEL

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform
terraform version
```

### Ubuntu / Debian

```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
```

Expected: Terraform 1.6 or newer. The project was built with 1.16.3.

---

## 2.4 kubectl

```bash
KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

> **Important environment quirk:** on the original host, `kubectl` resolved to a
> k3s wrapper pointed at a local cluster. Before any EKS command, check:
>
> ```bash
> which kubectl
> kubectl config current-context
> export KUBECONFIG="$HOME/.kube/config"
> ```
>
> If the context is `default` / `localhost`, you are pointed at the wrong
> cluster. Do not run writes until `kubectl get nodes` shows EKS nodes.

---

## 2.5 Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

Expected: Helm 3.14 or newer.

---

## 2.6 Docker

### AlmaLinux / RHEL

```bash
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and back in (or run `newgrp docker`) so the group applies. Verify:

```bash
docker version
docker run --rm hello-world
```

### Ubuntu / Debian

Install Docker Engine from Docker's official repository, then add your user to
the `docker` group. Do not use `sudo docker` for the build if you can avoid it —
file ownership problems are easier to reason about with rootless/group access.

---

## 2.7 GitHub access

The original build authenticated over SSH:

```bash
ssh -T git@github.com
```

Expected: `Hi <username>! You've successfully authenticated...`.

If you do not have a key:

```bash
ssh-keygen -t ed25519 -C "<YOUR_EMAIL>"
cat ~/.ssh/id_ed25519.pub
```

Add the public key to GitHub → Settings → SSH and GPG keys. Never share the
private key.

If you prefer HTTPS + a Personal Access Token (PAT), that also works, but do not
write the token into shell history or a tracked file. Use a credential helper.

---

## 2.8 Clone the repository

```bash
git clone git@github.com:<GITHUB_OWNER>/<GITHUB_REPO>.git
cd <GITHUB_REPO>
git status
```

Expected: clean working tree on `main` (or your working branch).

Set a local Git identity if needed:

```bash
git config user.name "<YOUR_NAME>"
git config user.email "<YOUR_EMAIL>"
```

---

## 2.9 Project-level verification

Run the read-only checks before touching AWS:

```bash
terraform -chdir=infra/terraform version
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate
helm lint charts/secureops -f charts/secureops/values-staging.yaml
docker compose config --quiet
```

`terraform init -backend=false` downloads providers/modules without needing the
S3 state bucket. It is the safe pre-bootstrap check.

Expected failures at this stage are acceptable if they are clearly about the
missing remote state; anything else (invalid HCL, missing provider, bad Helm
template) must be fixed now.

---

## 2.10 Tool version snapshot

Record what you used:

```bash
{
  echo "date: $(date -u +%FT%TZ)"
  echo "aws: $(aws --version 2>&1)"
  echo "terraform: $(terraform version -json | jq -r .terraform_version)"
  echo "kubectl: $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
  echo "helm: $(helm version --short)"
  echo "docker: $(docker version --format '{{.Server.Version}}')"
  echo "git: $(git --version)"
} | tee workstation-versions.txt
```

`workstation-versions.txt` is intentionally not ignored; keep it with your
notes, not in the public portfolio unless it contains no private data.

**Next:** prove the application runs locally in `03-repo-and-local-environment.md`.
