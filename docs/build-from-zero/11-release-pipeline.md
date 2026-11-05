# 11 — Release Pipeline: Build, Scan, Push

**Goal:** produce immutable, scanned images in ECR and pin them in Git so
ArgoCD can deploy them.

**Time:** 5–10 minutes per release. **Cost:** Actions minutes + ECR storage.
**Safety:** `STATE-CHANGING` (pushes to ECR).

Workflow: `.github/workflows/release.yml`.

---

## 11.1 Trigger

```yaml
on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      tag: ...
```

Every push to `main` produces a `sha-<12>` tag. A manual run can override the
tag, but normal flow is commit-driven.

---

## 11.2 The gate: never push unscanned bytes

For each image, the workflow does:

1. Configure AWS credentials via OIDC.
2. Log in to ECR.
3. Build the image **locally** with `push: false`, `load: true`.
4. Run Trivy with `severity: HIGH,CRITICAL` and `exit-code: "1"`.
5. If the scan passes, `docker push` the exact local image object.
6. Upload SARIF to the GitHub Security tab (`if: always()`).

Why not `build-push-action` with `push: true`? That would push **before** the
scan. Build attestations/SBOMs were intentionally disabled for the same reason:
they require push-during-build, which breaks the scan-before-push guarantee.
The trade-off is fewer provenance attestations; the benefit is that the bytes
scanned are the bytes stored.

ECR scan-on-push remains enabled as a backstop, not as the primary gate.

---

## 11.3 Tag policy

- Format: `sha-<first 12 chars of commit SHA>`.
- Tags are **immutable** in ECR. Re-pushing the same tag fails.
- `latest` is not pushed. Never deploy `latest`: it hides what is running.
- Release tags (`v1.2.3`) are also immutable if you use them.

The workflow's `meta` job resolves the tag once and both image jobs use it.

---

## 11.4 Steps to release

1. Merge application/code changes to `main`.
2. Watch the `Release` workflow.
3. If it passes, note the tag from the summary.
4. Update `charts/secureops/values-staging.yaml`:

```yaml
backend:
  image:
    repository: <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-backend
    tag: "sha-<12>"
frontend:
  image:
    repository: <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-frontend
    tag: "sha-<12>"
```

5. Commit and push the values change.
6. ArgoCD detects the commit, runs the migration Job, and rolls the pods.
7. Verify (Chapter 15).

> The original project's live tag was `sha-4ea08538f439`. That is historical,
> not something to reuse.

---

## 11.5 Verify the push

```bash
aws ecr describe-images \
  --repository-name secureops-staging-backend \
  --region ap-south-1 \
  --query 'imageDetails[].[imageTags[0],imagePushedAt,imageScanStatus.status]' \
  --output table
```

Expected: your `sha-*` tag with a recent timestamp and `COMPLETE` scan status.
The scan status is ECR's backstop; the Trivy gate already ran in CI.

Check that the image is pullable:

```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com
docker pull <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-backend:sha-<12>
```

---

## 11.6 If the gate fails

1. Read the Trivy table in the failed step. It lists package, installed version,
   fixed version, severity.
2. Classify:
   - OS package → `apk upgrade` / rebuild.
   - Language dependency → bump.
   - No fix in current major → upgrade the major (Laravel 11 → 12 was this case).
3. Fix, commit, push. A new commit gets a new tag.
4. Never lower the severity threshold or add a blanket ignore to ship.

If only the SARIF upload fails, the gate may still have passed. Check the push
step and ECR; do not assume the image is vulnerable.

---

## 11.7 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `tag already exists ... IMMUTABLE` | reused tag | push a new commit; never overwrite |
| `Not authorized ... AssumeRoleWithWebIdentity` | OIDC trust mismatch | fix trust/role variable |
| Trivy `GetDownloadUrlForLayer` denied | missing ECR pull permission | add it to the release role |
| `Aqua Security action tag not found` | upstream deleted/renamed action | pin an existing tag; check tags API |
| SARIF upload fails | `security-events` permission missing | keep `security-events: write` |
| Push succeeds but ArgoCD unchanged | values tag not updated | commit the tag pin |

**Next:** package the workloads in `12-helm-chart.md`.
