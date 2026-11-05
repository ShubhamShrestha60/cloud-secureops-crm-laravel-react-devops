# 01 — Accounts, Budget, and Domain

**Goal:** create the foundations that everything else depends on, and put a
financial guardrail in place *before* any billable resource exists.

**Time:** 20–30 minutes. **Cost:** $0 except the domain you already own.
**Safety:** account and DNS changes are `STATE-CHANGING`; deleting records or
users is `DESTRUCTIVE`.

---

## 1.1 AWS account hygiene

You need one AWS account. Do not build this in a shared account you do not
control.

### Root user

1. Sign in as the root email.
2. Enable MFA on the root user (console → Security credentials).
3. Do not create root access keys.
4. Create a separate administrative IAM user or, better, use IAM Identity
   Center (SSO) if available.

### Administrative user (simple path)

Console → IAM → Users → Create user → attach `AdministratorAccess` for the
build. This is broad and temporary. For anything long-lived, replace it with
scoped roles.

Create an access key only if you need CLI access from this workstation:

```bash
# READ-ONLY after creation (you are only verifying identity)
aws configure
# AWS Access Key ID:     <paste>
# AWS Secret Access Key: <paste>
# Default region name:   ap-south-1
# Default output format: json
aws sts get-caller-identity
```

Expected output: your user ARN and the 12-digit account ID. Save the account ID
as `<ACCOUNT_ID>` for later commands.

> **Clock warning:** if `aws sts get-caller-identity` fails with
> `InvalidSignatureException` / "Signature expired", fix the system clock before
> debugging credentials:
>
> ```bash
> sudo chronyc -a makestep     # AlmaLinux/RHEL with chrony
> # or: sudo timedatectl set-ntp true
> ```

### Region

This project uses **`ap-south-1` (Mumbai)**. Keep every resource in that region
unless you deliberately redesign it. ACM certificates must be in the same
region as the ALB.

---

## 1.2 Create the budget guardrail first

Do this before Terraform. It is the single most important cost control.

Find your account ID:

```bash
aws sts get-caller-identity --query Account --output text
```

Create a monthly cost budget (replace the amount with a number you can afford):

```bash
cat > /tmp/secureops-budget.json <<'JSON'
{
  "Budgets": [
    {
      "BudgetName": "secureops-monthly",
      "BudgetLimit": { "Amount": "20", "Unit": "USD" },
      "TimeUnit": "MONTHLY",
      "BudgetType": "COST"
    }
  ]
}
JSON

aws budgets create-budget \
  --account-id <ACCOUNT_ID> \
  --budget file:///tmp/secureops-budget.json \
  --region us-east-1
```

Add an email notification at 50%, 80%, and 100% of the budget:

```bash
for threshold in 50 80 100; do
  aws budgets create-notification \
    --account-id <ACCOUNT_ID> \
    --budget-name secureops-monthly \
    --notification "{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":${threshold},\"ThresholdType\":\"PERCENTAGE\"}" \
    --subscribers "[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"<YOUR_EMAIL>\"}]" \
    --region us-east-1
done
```

Verify:

```bash
aws budgets describe-budgets --account-id <ACCOUNT_ID> --region us-east-1 \
  --query 'Budgets[].BudgetName'
```

Also enable the free AWS Free Tier usage alerts in the Billing console, and
consider a CloudWatch billing alarm. Budgets are not a hard cap: they notify,
they do not stop resources. That is why teardown discipline matters.

> **Historical note:** this guardrail did not exist at the start of the original
> project. An unexpected bill followed. Never repeat that ordering mistake.

---

## 1.3 Domain and DNS (Cloudflare)

The original deployment used Cloudflare for DNS and kept the apex site separate.
You can skip this section if you set `domain_name = ""` and use the ALB hostname.

### Nameservers

Point the domain's nameservers at Cloudflare (registrar → custom nameservers).
Wait for propagation:

```bash
dig +short NS example.com @1.1.1.1
```

Expected: two `*.ns.cloudflare.com` names.

### Apex website

The apex site is not part of this stack. In the original setup, Cloudflare
proxied the apex to Vercel. Leave it alone; only create the staging record.

### Application record (after the ALB exists)

Do **not** create this yet. You need the ALB hostname from Chapter 14. When you
have it:

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | `staging` | `<ALB_DNS_NAME>` | **DNS only (grey cloud)** |

Why DNS-only: ACM validation and direct ALB TLS termination. An orange-cloud
proxy would terminate TLS at Cloudflare and hide the origin certificate from
ACM's validation path.

### CAA records (important)

Certificate Authorities checked CAA records before issuing. A malformed record
caused a real `CAA_ERROR` in this project. In Cloudflare, the CAA UI asks for
"Tag" and "Value"; the tag should be `issue` (not the literal phrase shown in
some dropdowns) and the value should be a bare domain.

Minimum safe records:

| Type | Name | Value |
|---|---|---|
| CAA | `@` | `0 issue "amazon.com"` |
| CAA | `@` | `0 issue "letsencrypt.org"` |

If you use another CA, add it. Verify from outside Cloudflare:

```bash
dig +short CAA example.com @1.1.1.1
```

Expected lines look like `0 issue "amazon.com"`. A value like
`0 issue "0 issue \"amazon.com\""` is malformed and will fail validation.

---

## 1.4 ACM certificate (manual in this build)

Terraform in this repo does **not** create the certificate. Request it after DNS
is under control, in the **same region as the ALB** (`ap-south-1`).

Console path: ACM → Request a public certificate → domain
`staging.example.com` → DNS validation → create the validation CNAME in
Cloudflare exactly as ACM shows it.

CLI equivalent:

```bash
aws acm request-certificate \
  --domain-name staging.example.com \
  --validation-method DNS \
  --region ap-south-1
```

Then read the validation record:

```bash
aws acm describe-certificate \
  --certificate-arn <ACM_CERT_ARN> \
  --region ap-south-1 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

Create that CNAME in Cloudflare (DNS-only). Wait for status `ISSUED`:

```bash
aws acm describe-certificate \
  --certificate-arn <ACM_CERT_ARN> \
  --region ap-south-1 \
  --query 'Certificate.Status'
```

Do not delete the validation CNAME after issuance. ACM re-checks it at renewal.

---

## 1.5 GitHub repository

You need a private repository for the full application and a separate public
repository for the sanitized portfolio. Create the private repo (or use an
existing one) and note:

- `<GITHUB_OWNER>/<GITHUB_REPO>` — for Terraform's OIDC trust and CI.
- The repo must be private if the application code must stay private.

Do not put secrets in repository variables that should be secrets. This build
uses OIDC for AWS auth and repository **Variables** only for non-secret values
(`AWS_REGION`, `AWS_ROLE_TO_ASSUME`, `ECR_*`).

---

## 1.6 Verification checklist

```bash
aws sts get-caller-identity                     # identity works, clock is sane
aws budgets describe-budgets --account-id <ACCOUNT_ID> --region us-east-1
dig +short NS example.com @1.1.1.1
dig +short CAA example.com @1.1.1.1
aws acm list-certificates --region ap-south-1
```

**Next:** install the workstation tools in `02-workstation-setup.md`.
