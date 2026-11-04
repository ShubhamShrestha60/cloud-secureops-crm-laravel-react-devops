# 05 — Network: VPC, Subnets, NAT, and Security Groups

**Goal:** build the network foundation: isolated private subnets for nodes and
RDS, public subnets for the ALB, one NAT gateway for egress, and tags that let
the AWS Load Balancer Controller find the right subnets.

**Time:** 3–5 minutes. **Cost:** NAT gateway is the expensive part (~$35/month
in Mumbai) plus data processing. **Safety:** `terraform apply` is
`STATE-CHANGING`; `destroy` is `DESTRUCTIVE`.

---

## 5.1 What the code creates

`infra/terraform/network.tf` uses the community VPC module:

| Resource | Staging value | Why |
|---|---|---|
| VPC CIDR | `10.0.0.0/16` | 65,536 addresses; room for growth. |
| AZs | 2 (`az_count = 2`) | Cost-efficient HA; prod template uses 3. |
| Private subnets | `10.0.0.0/24`, `10.0.1.0/24` | EKS nodes and RDS live here. |
| Public subnets | `10.0.100.0/24`, `10.0.101.0/24` | ALB and NAT live here. |
| NAT gateway | 1 (`single_nat_gateway = true` for staging) | Egress for private nodes; prod uses one per AZ. |
| DNS | hostnames + support enabled | Required for EKS and service discovery. |

Subnet tags are not cosmetic:

```hcl
public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
```

The AWS Load Balancer Controller discovers subnets by these tags. Missing tags
are why an Ingress can stay `ADDRESS`-less.

---

## 5.2 CIDR math you should be able to explain

`cidrsubnet("10.0.0.0/16", 8, i)` adds 8 bits to the prefix, producing `/24`
networks:

- `i = 0` → `10.0.0.0/24`
- `i = 1` → `10.0.1.0/24`
- public: `i + 100` → `10.0.100.0/24`, `10.0.101.0/24`

Using different third octets for public and private makes routing and security
group debugging much easier.

---

## 5.3 Apply just the network first

You can apply the whole stack at once, but applying the network first makes
failures easier to isolate:

```bash
cd infra/terraform
terraform apply \
  -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" \
  -target=module.vpc \
  -auto-approve
```

`-target` is a debugging tool, not a normal workflow. After it succeeds, run a
normal plan/apply for the rest.

Expected resources: VPC, 2 public subnets, 2 private subnets, internet gateway,
1 NAT gateway, 1 Elastic IP, route tables and associations.

---

## 5.4 Verify the network

```bash
VPC_ID=$(aws ec2 describe-vpcs --region ap-south-1 \
  --filters Name=tag:Name,Values=secureops-staging \
  --query 'Vpcs[0].VpcId' --output text)
echo "VPC_ID=$VPC_ID"

aws ec2 describe-subnets --region ap-south-1 \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].[CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`Name`]|[0].Value]' \
  --output table

aws ec2 describe-nat-gateways --region ap-south-1 \
  --filter Name=vpc-id,Values="$VPC_ID" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table
```

Expected:

- 1 VPC `10.0.0.0/16`.
- 2 private subnets (`MapPublicIpOnLaunch` false) and 2 public (`true`).
- 1 NAT gateway `available`.

Check route tables:

```bash
aws ec2 describe-route-tables --region ap-south-1 \
  --filters Name=vpc-id,Values=<VPC_ID> \
  --query 'RouteTables[].[RouteTableId,Tags[?Key==`Name`]|[0].Value,Routes[].DestinationCidrBlock]' \
  --output table
```

Private route tables should send `0.0.0.0/0` to the NAT gateway. Public route
tables should send it to the internet gateway.

---

## 5.5 Security groups

### RDS security group

`infra/terraform/rds.tf` creates the database SG with one ingress rule:

```hcl
ingress {
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [module.eks.node_security_group_id]
}
```

This says: only the EKS node security group may reach Postgres. It does not
allow the whole VPC, and it does not allow the internet. Verify after the
cluster exists:

```bash
aws ec2 describe-security-groups --region ap-south-1 \
  --filters Name=group-name,Values=secureops-staging-rds \
  --query 'SecurityGroups[].IpPermissions' --output json
```

The source should be an SG reference, not `0.0.0.0/0`.

### Node security group

The EKS module creates and manages it. Do not hand-edit rules that the module
owns; Terraform will revert them. If you need extra access, add it in code.

---

## 5.6 Cost notes

- NAT gateway: hourly charge plus per-GB processing. At low traffic, the hourly
  charge dominates. Staging uses **one** NAT instead of one per AZ to cut cost.
- Elastic IP attached to NAT: no separate idle charge while attached.
- Public IPv4 addresses on the ALB: charged hourly in current AWS pricing.
- Data transfer out: small for a demo, but watch it if you add downloads.

Sleeping nodes and stopping RDS does **not** remove the NAT gateway. Only
`terraform destroy` or deleting the NAT does. This is why "asleep" still costs
roughly $100/month.

---

## 5.7 Common network failures

| Symptom | Cause | Fix |
|---|---|---|
| ALB Ingress has no address | subnets missing LB role tags | verify tags from Chapter 14 |
| Nodes cannot pull images | no NAT / route to internet | check private route table and NAT state |
| RDS timeout from pods | wrong SG source or wrong DB host | confirm SG rule uses node SG; test from a pod |
| `InvalidSubnet` during apply | CIDR overlaps or AZ capacity | check `az_count` and VPC CIDR |
| `terraform destroy` hangs on VPC | ENIs/ALB still attached | delete Kubernetes LB resources first, then destroy |

**Next:** create the cluster and node group in `06-eks-cluster-nodes-addons.md`.
