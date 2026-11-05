# Part IX — Troubleshooting and incident response

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

Method first (Ch. 8.6): one-sentence symptom → ladder order → single hypothesis
fitting ALL outputs → cheapest disproof → minimal git-tracked fix → Layer 1–3
verify → runbook note. Each scenario below follows: symptoms, likely causes,
first checks, evidence commands, interpretation, isolation, remediation,
verification, prevention. All commands tagged; assume `KUBECONFIG` exported.

## T1 — OIDC `Not authorized to perform sts:AssumeRoleWithWebIdentity`

1. Symptoms: `configure-aws-credentials` retries ~12× then fails; no CloudTrail
   events for the role.
2. Causes (ranked): (a) `sub` mismatch incl. numeric-ID format, (b) wrong
   `AWS_ROLE_TO_ASSUME` value/whitespace/Secrets-vs-Variables, (c) stale
   provider thumbprint, (d) eventual consistency after role creation.
3. First checks: paste variable values verbatim; `get-role` trust vs expected.
4. Evidence: temporary workflow step fetching the OIDC JWT and printing
   `aud/sub/iss` (never the token) — ours revealed
   `repo:OWNER@id/REPO@id:ref:…`; `get-open-id-connect-provider` thumbprints.
5. Interpret: token valid + zero STS calls for the role = trust never matched
   (not a policy/permission fault).
6. Isolate: character-compare sub vs `StringLike` pattern.
7. Remediate: `repo:<owner>@*/<repo>@*:*` pattern (split owner/repo in TF);
   refresh thumbprints to live chain roots; remove debug step after.
8. Verify: re-run job assumes role first try.
9. Prevention: decode-claims snippet kept in Ch. 9; Dependabot doesn't cover
   trust semantics — review on any GitHub OIDC format notice.

## T2 — Trivy gate fails (real CVEs)

1. `Trivy scan *` exit 1 with CVE table (ensure `format: table` — SARIF-only
   hides findings in un-uploaded files).
2. Causes: stale base OS packages; outdated composer/npm deps; EOL major
   (our Laravel 11 case: fix exists only on v12+).
3. Checks: classify OS vs language vs major-jump; `composer audit` / `npm audit`.
4. Evidence: Installed vs Fixed columns dictate the fix (rebuild vs bump vs
   upgrade); `composer.json` platform must equal runtime PHP (our Symfony-8-on-8.3
   build break came from a newer-PHP toolbox resolving the lock).
5. Isolate: reproduce build locally (`docker build`) before pushing fixes.
6. Remediate: `apk upgrade` stages; minor bumps; major upgrade with full suite;
   single-CVE `.trivyignore` with expiry comment only as last resort.
7. Verify: green Release + `describe-images` shows the new tag (gate proof).
8. Prevention: Dependabot, digest-pinned bases (backlog), never lower severity
   to ship.

## T3 — ECR immutable-tag collision

1. `…tag 'latest' already exists … IMMUTABLE` on push.
2. Cause: floating tag re-pushed (our pre-gate workflow did this).
3. Checks: `describe-images` tag list; what references the tag (values files).
4. Evidence: collision proves the tag already points at *different* bytes.
5. Remediate: stop pushing `latest` (done here); delete only unreferenced tags.
6. Verify: push succeeds; ArgoCD values never mention `latest`.
7. Prevention: sha-only tagging enforced by workflow shape, not discipline.

## T4 — Pods Pending (`FailedScheduling`)

1. Symptoms: `Pending`, scheduler event names the constraint.
2. Causes seen: ENI pod-density cap (11 on t3.small vs 26 pods → `Too many pods`);
   requests exceeding allocatable; taints/cordon during drains.
3. Checks: `describe pod` Events; `describe node` Allocated; `get nodes` count.
4. Interpret: "Too many pods" = density (add nodes, not bigger requests);
   "Insufficient memory/cpu" = requests (right-size or scale).
5. Remediate: nodegroup desired up (API-managed!); never lower requests to
   force-fit.
6. Verify: pods schedule + Running; site 200s.
7. Prevention: capacity math in sizing reviews (Ch. 8.5).

## T5 — CrashLoop: nginx config / permissions

1. Symptoms: `CrashLoopBackOff`, restarts climbing.
2. Our three variants: (a) `host not found in upstream "backend"` — startup DNS
   (fix: `resolver`+variable, Ch. 5); (b) `/var/lib/nginx/*` denied as
   www-data (fix: mkdir+chown in Dockerfile); (c) `/tmp/nginx.pid` read-only
   under `readOnlyRootFilesystem` (fix: `emptyDir /tmp` + main-conf paths).
3. Checks: `logs deploy/…` first lines (nginx `emerg` names the exact path);
   `securityContext` + volumeMounts second.
4. Interpret: `emerg` at start = config/filesystem (fix image/chart), never app code.
5. Remediate in image or chart; verify locally (`docker run … nginx -t` as the
   runtime UID; frontend HTTP 200 container test) before pushing.
6. Prevention: non-root container smoke test in CI (backlog).

## T6 — ArgoCD red: allowlist / secret / waves / types

1. Symptoms: app `OutOfSync`/`Unknown`/`Degraded`, or resources `Missing`.
2. Decision tree: `describe application` Conditions FIRST —
   `not permitted in project` → fix `sourceRepos` (our repo-rename case);
   else check namespace resources: migrate `CreateContainerConfigError` +
   missing Secret → ExternalSecret/wave ordering (apply order + wave `-10`,
   Ch. 5); else controller logs for `failed to parse … annotation`
   (our `ssl-redirect: "true"` bool-vs-port).
3. Remediate live to unblock, codify in git immediately (unblocking without
   codifying is how drift is born).
4. Verify: `Synced` + fresh-revision pods + endpoints.
5. Prevention: `helm template --show-only` diffs in PRs; waves documented on
   the templates themselves.

## T7 — DNS / TLS failures

1. Symptoms: curl `000`/timeout (DNS), cert warnings (TLS), ACM `FAILED`.
2. Causes: CNAME absent/proxied (must be DNS-only for validation), `CAA_ERROR`
   (malformed or missing issuer authorization — our doubled-value saga),
   cert-region mismatch (ACM must equal ALB region), `ssl-redirect` type error.
3. Checks: direct queries to 1.1.1.1 for CNAME/A/CAA; `describe-certificate`
   Status + FailureReason; `describe-listeners` (443 + cert ARN present?).
4. Interpret: `PENDING_VALIDATION` + resolving CNAME = wait; `FAILED` = read
   FailureReason and fix the named cause (each ACM request mints fresh values;
   failed certs are never retried — delete + re-request).
5. Prevention: never delete validation CNAMEs; calendar-check expiry-30d.

## T8 — Terraform plan/apply surprises

1. Symptoms: unexpected adds/destroys, perpetual diffs, 400s from AWS.
2. Catalogued: EKS 1.30 AMI deletion (bump minor, stepwise only); WAF
   association re-created every plan (harmless no-op); node `desired_size`
   never diffs (module `ignore_changes` — API-managed); LB-webhook race
   (serialize releases); OIDC provider single-per-account (`state rm`
   transition, Ch. 4.6).
3. First check is always full `plan` output, not the summary line.
4. Remediate per case; verify with targeted `describe-*` (AWS truth) + second
   clean `plan`.
5. Prevention: pin versions, read module `lifecycle` blocks before sizing
   debates, keep TF and ClickOps changes strictly separated.

## T9 — Database connectivity / data incidents

1. Symptoms: migration failures, 500s on DB paths, login 422-shape anomalies.
2. Causes: wrong `DB_HOST` (ESO lag after rotation — restart pods; env is
   boot-time), SG source drift, RDS stopped (sleep state or 7-day auto-wake),
   empty tables (unseeding — our login 422 with `users=0`).
3. Checks: ESO `SecretSynced`? pod env present? (`describe`, never `env`
   dumps) `tinker` counts; SG rule source; RDS status.
4. Remediate: re-point secret → restart pods; re-seed with explicit env (never
   defaults in shared envs); restore drill for loss (Ch. 11).
5. Prevention: seedverification in wake checks; backup drill calendar.

## T10 — Monitoring blind spots

1. Symptoms: incident found by human, not alarm; `kubectl top` fails.
2. Causes: no metrics-server (HPA blind), no email subscriber, no ALB access
   logs, pod logs ephemeral.
3. Checks: `get hpa` (exists ≠ working); SNS subscriptions; alarm history.
4. Remediate in priority order: metrics-server → email subscription → access
   logs → Prometheus/Grafana (backlog with costs).
5. Prevention: every new component ships with its alarm in the same PR.

## T11 — Performance degradation

1. Symptoms: rising latency (ALB `TargetResponseTime`), CPU alarms, OOMKills
   (`describe pod` + `dmesg`-class events).
2. Causes: traffic growth, N+1 queries (app-side), noisy-neighbor (shared
   small nodes), HPA blind (see T10).
3. Checks: CloudWatch latency/5xx/request-count triad before touching anything;
   per-node Allocated for noisy-neighbor evidence.
4. Remediate: scale nodes (API) before upsizing classes; app fixes for query
   pathologies; CDN/CF caching for static (already immutable-cached).
5. Prevention: load-test before traffic claims; record baselines now while
   quiet (backlog).

## T12 — Surprise cloud bill

1. Symptoms: budget alarm / console total above run-rate table (Ch. 11).
2. Causes ranked by this repo's history: forgotten idle (nodes/RDS left awake
   post-demo — sleep routine exists for this), unattached EIPs/volumes/
   snapshots, data-transfer growth, second ALB nobody removed, WAF request
   fees under attack traffic (check WAF metrics first).
3. Checks: Cost Explorer monthly-by-service; orphan hunts (Ch. 9 §11).
4. Remediate: sleep/terminate/delete per case; raise don't ignore alarms —
   retune thresholds to the current run-rate after every sizing change.
5. Prevention: monthly 30-second review habit; tag everything (already
   default-tagged); sleep-by-default operating model.
