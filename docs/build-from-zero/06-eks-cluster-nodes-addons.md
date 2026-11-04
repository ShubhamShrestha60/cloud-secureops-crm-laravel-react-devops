# 06 — EKS Cluster, Nodes, and Add-ons

**Goal:** create the Kubernetes control plane, a managed node group sized for
this workload, and the AWS-specific add-ons the chart depends on.

**Time:** 12–20 minutes. **Cost:** EKS control plane ~$73/month + nodes.
**Safety:** `terraform apply` is `STATE-CHANGING`; cluster deletion is
`DESTRUCTIVE`.

---

## 6.1 What the code creates

`infra/terraform/eks.tf`:

- EKS control plane version from `staging.tfvars` (`1.32`).
- Managed node group in **private** subnets, 3× `t3.small`, min 2, max 4.
- 30 GiB `gp3` EBS volume per node, deleted on termination.
- Managed add-ons: CoreDNS, kube-proxy, VPC CNI, EBS CSI driver.
- IRSA role for the EBS CSI controller.

`infra/terraform/addons.tf` additionally installs:

- AWS Load Balancer Controller `1.7.2` in `kube-system`.
- External Secrets Operator `0.10.4` in `external-secrets`.

---

## 6.2 Why 3× `t3.small` instead of 1 larger node

The binding constraint was **pod density**, not CPU or memory. A `t3.small`
supports roughly 11 pods per node because of ENI/IP limits. The workload needed
26 pods (4 app pods + system pods + migration/rollout headroom). Two nodes
could not fit 26 pods even if CPU/memory were free; three could.

The trade-off: three small nodes cost slightly less than two larger nodes but
leave thinner memory headroom and more node-level failure blast radius than a
larger, fewer-node design. Measure before changing instance types.

Node `desired_size` is **API-managed**. The upstream EKS module ignores changes
to desired size so an autoscaler can own it. Terraform will not put a running
node count back to the tfvars value. Change it deliberately:

```bash
aws eks update-nodegroup-config \
  --cluster-name secureops-staging \
  --nodegroup-name <NODEGROUP_NAME> \
  --region ap-south-1 \
  --scaling-config minSize=2,maxSize=4,desiredSize=3
```

---

## 6.3 Apply the cluster

From `infra/terraform`:

```bash
terraform plan \
  -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" \
  -out=tfplan
terraform apply tfplan
```

This creates the EKS control plane, node group, IRSA roles, and Helm releases
for the two controllers. It can take 15–20 minutes. Do not interrupt it.

If the Helm release for External Secrets fails because the chart repository is
unreachable, retry; if it fails because of a webhook race, see Chapter 13.

---

## 6.4 Connect kubectl

```bash
aws eks update-kubeconfig \
  --name secureops-staging \
  --region ap-south-1

kubectl config current-context
kubectl get nodes -o wide
```

Expected: 3 nodes `Ready`, all in private subnets (no public IP), EKS-optimized
AMI.

If you see `localhost.localdomain` or connection refused, your `kubectl` is
pointing at a local k3s cluster:

```bash
which kubectl
export KUBECONFIG="$HOME/.kube/config"
kubectl config get-contexts
```

---

## 6.5 Verify add-ons

```bash
kubectl -n kube-system get deploy
kubectl -n kube-system get pods | grep -E 'aws-load-balancer|ebs-csi|coredns'
kubectl -n external-secrets get pods
```

Expected: all deployments available, pods `Running`.

Check EBS CSI IRSA:

```bash
kubectl -n kube-system get sa ebs-csi-controller-sa -o yaml | grep -A2 'eks.amazonaws.com/role-arn'
```

Check Load Balancer Controller:

```bash
kubectl -n kube-system get sa aws-load-balancer-controller -o yaml | grep -A2 'eks.amazonaws.com/role-arn'
```

Both should show an IAM role ARN. If the annotation is missing, the controller
cannot call AWS and Ingress/volumes will fail.

Check ESO IRSA:

```bash
kubectl -n external-secrets get sa external-secrets -o yaml | grep -A2 'eks.amazonaws.com/role-arn'
```

---

## 6.6 Verify OIDC discovery

IRSA needs the cluster's OIDC provider:

```bash
aws eks describe-cluster \
  --name secureops-staging \
  --region ap-south-1 \
  --query 'cluster.identity.oidc.issuer' --output text

aws iam list-open-id-connect-providers
```

The issuer URL should match the provider URL (without the `https://` prefix in
the IAM ARN). Terraform creates the provider through the EKS module. If you
delete/recreate the cluster, the provider ID changes and IRSA roles must be
updated.

---

## 6.7 Node capacity math

```bash
kubectl describe node | grep -A6 'Allocated resources'
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.capacity.pods
```

Capacity per `t3.small` is typically 11 pods (ENI-dependent). Compare:

- Sum of pod requests on each node vs node allocatable.
- Number of pods vs the ENI cap.
- System pods that must run on every node.

Do not lower requests just to force-fit. Add a node or change instance type with
the cost table open.

---

## 6.8 Upgrades (stepwise)

EKS does not allow skipping minor versions. The safe order is:

1. Read the EKS upgrade guide for the target version.
2. Upgrade the control plane.
3. Upgrade the node group (or replace nodes with a new group).
4. Upgrade add-ons that require it.
5. Verify workloads.

The original project moved from 1.30 to 1.32 in steps. A Terraform plan that
tries to jump multiple minors is a red flag.

---

## 6.9 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl` connects to localhost | k3s wrapper / wrong context | export `KUBECONFIG`, update kubeconfig |
| Nodes `NotReady` | VPC CNI or subnet routing | check node logs, NAT, security groups |
| Pods `Pending` `Too many pods` | ENI density cap | add nodes; do not shrink requests |
| Load Balancer Controller CrashLoop | IRSA annotation or IAM policy missing | re-check SA annotation and Terraform apply |
| ESO `InvalidProviderConfig` | ESO IRSA role cannot read the secret path | check role ARN and Secrets Manager path permissions |
| `terraform destroy` cannot delete node group | desired size changed via API | set desired to 0 before destroy, or let Terraform drain |

**Next:** create RDS and the secret store in `07-rds-secrets.md`.
