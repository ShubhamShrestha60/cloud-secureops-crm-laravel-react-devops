# Interview Stories

STAR format, backed by files in this repository. Use the details you can defend
from the code; do not invent traffic or revenue numbers.

---

## 1. Scan-before-push image pipeline

**Situation:** The first release design used a build-and-push action that pushed
the image and then scanned it. That means vulnerable bytes can reach ECR before
the gate reports a problem.

**Task:** Make the registry contain only scanned images without giving up
immutable tags.

**Action:** Split the job: build locally with `push: false, load: true`, run
Trivy at `HIGH,CRITICAL` with `exit-code: 1`, and only then `docker push` the
exact local image. Disabled build attestations/SBOMs because they require
push-during-build. Kept ECR scan-on-push as a backstop, not the primary gate.

**Result:** A failed scan means nothing is pushed. Tags are immutable
`sha-<commit>`, so the deployed bytes are the scanned bytes. Documented the
trade-off (no provenance) instead of claiming it.

**Follow-up:** For attestations without breaking the gate, scan locally, push by
digest, then attest the digest.

File: `.github/workflows/release.yml`.

---

## 2. Keyless AWS authentication with OIDC

**Situation:** The easy path is an IAM user access key in GitHub Secrets. That is
a long-lived credential with a large blast radius.

**Task:** Let GitHub Actions push to ECR without static AWS keys.

**Action:** Created a GitHub OIDC provider and a role whose trust policy matches
`aud = sts.amazonaws.com` and a `sub` pattern scoped to the repository and ref.
The role can only obtain ECR auth and push/pull the two repositories. The workflow
requests `id-token: write` and uses `aws-actions/configure-aws-credentials`.

**Result:** No AWS keys in GitHub. Trust is repo/ref-scoped, and permissions are
ECR-only. Documented the common `AssumeRoleWithWebIdentity` failure as a trust
mismatch, not an ECR permission problem.

**Follow-up:** Add environment-scoped trust (`environment:production`) and
required reviewers for release runs.

Files: `infra/terraform/iam-github-oidc.tf`, `.github/workflows/release.yml`.

---

## 3. Nginx fails at startup because of an upstream DNS name

**Situation:** The frontend container exited with
`nginx: [emerg] host not found in upstream "backend"`. The frontend was supposed
to start in environments where the compose service name `backend` did not exist,
including Kubernetes.

**Task:** Keep the local `/api` proxy useful without making nginx depend on that
name at startup.

**Action:** Moved the upstream into a variable and added a `resolver` directive.
Nginx then resolves the name at request time instead of startup. On EKS the ALB
routes `/api/*` directly to the backend Service, so the proxy is only a local
fallback.

**Result:** The image starts in both compose and Kubernetes. The failure is now a
documented trap in the Docker chapter rather than a recurring outage.

File: `frontend/nginx.conf`.

---

## 4. A migration must not race a rolling deploy

**Situation:** The backend entrypoint ran `php artisan migrate --force` on every
container start. During a rolling update, several pods can start at once, so
migrations can race.

**Task:** Run migrations exactly once, before new application pods serve.

**Action:** Set `SKIP_MIGRATIONS=true` on the Deployment and moved migrations into
a Helm `pre-install,pre-upgrade` Job. Added an ArgoCD sync wave of `-5` for the
Job and `-10` for the ExternalSecret, so the secret exists before the Job and the
Job finishes before Deployments roll.

**Result:** One migration owner, deterministic ordering, and the same chart works
under Helm or ArgoCD. The failure mode (`CreateContainerConfigError` when the
secret is missing) is documented with the wave numbers.

Files: `backend/docker/entrypoint.sh`,
`charts/secureops/templates/migrate-job.yaml`,
`argocd/apps/staging.yaml`.

---

## 5. Proving a backup is actually restorable

**Situation:** RDS automated backups existed, but no one had restored one. A
backup you have never restored is a hope, not a recovery plan.

**Task:** Prove the snapshot can produce the same data, and learn what the restore
requires.

**Action:** Took a manual snapshot, restored it to a disposable instance,
compared row counts against the source (`users=2`, `contacts=13`, `logs=13`), then
deleted the test instance. The first restore exposed a placement issue: without
an explicit subnet group and VPC security group, the instance can land in the
default VPC and be unreachable.

**Result:** Counts matched, the drill is repeatable, and the runbook now requires
subnet/SG parameters. Also documented what the drill did not prove: PITR to an
arbitrary second, large-data restore time, and key rotation.

File: `docs/build-from-zero/17-sleep-wake-backup-restore.md`.

---

## 6. Teardown is an engineering task, not a delete button

**Situation:** After a full teardown, the account still had an ALB, a listener,
and two target groups. The cluster had been deleted first, so the AWS Load
Balancer Controller that owned them was gone. The state bucket had also been
deleted manually, so Terraform could not reconcile.

**Task:** Remove every billable resource without deleting the wrong thing, and
write the order down so it does not happen again.

**Action:** Deleted the Application, then the Ingress/ALB before the cluster.
When Terraform could not read state, inventoried the account directly: EKS, RDS,
EC2, NAT, EIPs, EBS, ELBs, target groups, log groups, snapshots, WAF, alarms.
Deleted the orphaned listener, LB, and target groups manually. Documented the
correct order: state last, ALB before cluster, sweep after destroy.

**Result:** The account was clean, and the runbook now explains why deleting the
state bucket first is dangerous. The lesson: teardown has dependencies, just like
deployment.

File: `docs/build-from-zero/18-teardown-zero-cost.md`.

---

## 7. The cost lesson: idle is not free

**Situation:** Scaling nodes to zero and stopping RDS felt like "off". The bill
still had a floor from the EKS control plane, NAT gateway, ALB, WAF, and storage.

**Task:** Make the cost model explicit and add guardrails.

**Action:** Measured the awake/asleep difference, documented the fixed-cost
components, added budget/anomaly commands, and made the teardown checklist the
default for long pauses. Documented that RDS auto-restarts after 7 days.

**Result:** The public record states ~$199/month awake and ~$100/month asleep, and
names the floor. The financial postmortem stays private; the engineering controls
are public.

Files: `docs/build-from-zero/19-cost-guardrails.md`, `ops/sleep.sh`.

---

## 8. Choosing pull-based GitOps

**Situation:** A push-based deploy needs cluster credentials in CI. That turns a
CI compromise into a cluster compromise.

**Task:** Deploy without giving CI a kubeconfig.

**Action:** CI pushes images and commits a tag. ArgoCD, running in-cluster, pulls
the chart and reconciles. Added `prune` and `selfHeal`, and used sync waves for
secret/migration ordering.

**Result:** CI cannot delete namespaces or read cluster secrets. The trade-off is
that ArgoCD becomes critical infrastructure, and `selfHeal` reverts manual
hotfixes. Both are documented.

Files: `argocd/apps/staging.yaml`, `docs/build-from-zero/13-argocd-gitops.md`.

---

## How to answer "what went wrong?"

Pick one story and separate **symptom**, **root cause**, **fix**, and **guardrail**.
Example: the nginx upstream failure was a symptom; the root cause was startup-time
DNS resolution; the fix was a resolver + variable; the guardrail was documenting
it and keeping the EKS path free of that dependency.

Do not answer with "it worked after I retried." Retrying without a root cause is
not an engineering answer.
