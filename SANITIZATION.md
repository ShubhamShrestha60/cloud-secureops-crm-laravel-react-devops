# Sanitization

This repository is a curated copy of the DevOps surface of a private project. The
private repository retains the application source and the full history.

## What was removed

| Removed | Why |
|---|---|
| `backend/app/`, `backend/routes/`, `backend/config/`, migrations, tests | application source is private |
| `frontend/src/`, `public/`, package lock/build config | application source is private |
| private Git history | it contains account-specific commits and messages |
| `.env` files | may contain real values |
| Terraform state and plan files | contain resource IDs and sensitive outputs |
| `project_dump.txt` | contains the full private tree |
| `vendor/`, `node_modules/`, build output | generated, not evidence |
| the private financial postmortem | intentionally kept out of the public record |
| GitHub PAT / ArgoCD repo credential | secret; never published |

## What was replaced

| Original | Replacement |
|---|---|
| real AWS account ID | `<ACCOUNT_ID>` |
| private repository URL/name | `https://github.com/<GITHUB_OWNER>/<GITHUB_REPO>.git` |
| full ACM certificate ARN | `<ACM_CERT_ARN>` |
| certificate UUID fragment | `<CERT_ID>` |
| demo admin password | `<CHANGE_ME>` |
| demo DB password values | `<DB_PASSWORD>` |
| demo Laravel `APP_KEY` | `<APP_KEY>` |

The archived hostname `staging.shubham-shrestha.com.np` is retained intentionally
as a concrete example. It no longer serves the application.

## What was kept

- All Terraform, Helm, ArgoCD, workflow, Docker, nginx, and ops files.
- The complete 21-chapter rebuild manual and reference indexes.
- The public project journal with the financial section removed.
- Observed row counts from the restore drill (`users=2`, `contacts=13`,
  `logs=13`) because they are small and demonstrate the verification method.

## Verification

Before publishing, these searches must return no sensitive values:

```bash
grep -rn "<ACCOUNT_ID>\|<GITHUB_OWNER>\|<CERT_ID>\|<CHANGE_ME>" . || true
grep -rEn "arn:aws:[a-z0-9-]+:[a-z0-9-]+:[0-9]{12}" . || true
grep -rn "BEGIN .*PRIVATE KEY\|ghp_\|github_pat_" . || true
grep -rn "terraform.tfstate" . || true
```

Also confirm that no application source was copied:

```bash
find . -path './backend/app' -o -path './frontend/src' -o -name 'project_dump.txt'
```

Expected: no output.

## Residual identifiers

The following are non-secret but environment-specific and may still appear:

- Region `ap-south-1`.
- Example hostname noted above.
- Resource naming prefix `secureops`.
- Image tag `sha-4ea08538f439` in historical examples.

Replace or remove them if you reuse this material in a different context.

## Rule for future updates

Sanitize at the boundary. Do not copy the private working tree into this
repository and then delete files; copy only the allowlisted DevOps paths, apply
the replacements, and run the verification greps. Deleting after copying can
leave content in Git history.
