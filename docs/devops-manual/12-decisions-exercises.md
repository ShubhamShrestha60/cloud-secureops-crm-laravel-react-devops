# Part XI — Engineering decisions and alternatives

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

Each decision: what was done → why (plausible selection reason) → pros/cons →
cost/security consequences → alternatives + when preferable. Verdicts assume
*this* project: single-env public demo on tight credits.

## 11.1 EKS (managed K8s) vs leaner hosts

Done: EKS 1.32 + managed nodes ($73 fee + nodes). Why: credible managed-K8s
story, autoscaling primitives, AWS-integrated LB/secrets. Cost: fee dominates
(~37% of bill) regardless of traffic. Alternatives: k3s on EC2 (keeps "K8s"
truthfully, drops $73, adds ops burden), single-host compose (~$10/mo, drops
the K8s story entirely), Fargate (keeps fee, per-pod premium). Prefer leaner
when traffic is near-zero AND the resume doesn't need managed-K8s — here the
resume does, so EKS stays and sleep/wake carries the savings.

## 11.2 GitOps pull vs CI push deploys

Done: ArgoCD pull (Ch. 5). Pros: cluster needs no CI creds, drift self-heals,
rollback = revert. Cons: ArgoCD itself to operate; polling delay; app-manifest
blind spot (Ch. 10 T6). Push-based (`kubectl apply` from CI) would be simpler
and wrong here: long-lived cluster credentials in CI + no drift correction.
Prefer push only for throwaway preview envs.

## 11.3 Scan-before-push + immutable tags

Done: local build → gate → push exact bytes; sha-only immutable tags. Cost:
rebuild complexity + lost attestations (documented). Alternative (push-then-
scan, the AI original) is *not* a trade-off but a defect: it stocks the
registry with unscanned images. Keep unconditionally.

## 11.4 Secrets via ESO vs alternatives

Done: SM + ESO + IRSA. Pros: no secrets in git, ≤1-min rotation propagation,
per-path IAM. Cons: chain has 4 links (any breaks = `CreateContainerConfigError`);
boot-time env needs pod restarts. Alternatives: Sealed Secrets (git-storable
ciphertext, harder rotation), CSI driver mount (file-shaped secrets, renewal
semantics differ), plain K8s Secrets via CI (leaks into pipeline logs —
rejected). ESO stays; add SM versioning + rotation schedule (backlog).

## 11.5 Single env vs staging+prod

Done: one prod-like env; `*prod*` files are templates. Pros: half the bill,
half the ops. Cons: no safe blast radius for infra experiments; demo shares
fate with "prod". Prefer two envs when change velocity or compliance demands
it — this showcase's velocity is low and budget is binding. Honest resume
framing matters more than the second cluster.

## 11.6 Managed/Iterator choices, quick verdicts

- ALB+WAF over NLB: path routing + WAF + ACM integration justify ~$23/mo.
- RDS over container Postgres: backups/encryption/patching managed; $15 well spent.
- t3.small×3 over medium×2: same HA properties, $16 cheaper, thinner margin (measured).
- HPA present-but-blind (no metrics-server): install metrics-server before citing autoscaling.
- No service mesh/mTLS: correct deferral — internal HTTP + TLS-at-edge matches threat model.
- Dependabot + SARIF: near-zero cost, high interview value. Kept.

## 11.7 Prioritized backlog (evidence-ordered, not generic)

1. metrics-server (HPA real; capacity truth) — tiny cost, outsized value.
2. `npm audit` in CI + digest-pinned bases + cosign signing (supply chain depth).
3. `alert_email` + ALB target-health/pod-restart/cert-expiry alarms (close the loop).
4. HSTS + WAF Count-mode canary process for rule changes.
5. SM versioning/rotation schedule; CI guard against `secrets.create=true` outside demos.
6. ArgoCD GitHub-SSO front door (planned in Ch. 12-session; +~$18/mo ALB) — only if UI-in-browser need returns.
7. Load-test baselines before any traffic claim; PITR drill variant.
8. Second environment — only on funded need, never for symmetry.

---

# Part XII — Exercises and interview preparation

Attempt before reading the answer. Each answer states the evidence chain.

## E1 — Architecture (easy): trace a login end to end

*Task:* Whiteboard every hop of `POST /api/v1/login` naming the component,
protocol change, and credential check at each trust boundary.
*Answer sketch:* Browser→Cloudflare DNS→WAF→ALB:443 (TLS ends, WAF inspects)→
Ingress `/api`→Service:80→pod:8080→nginx→php-fpm:9000→throttle→validation→
Sanctum token; DB via ESO env + node-SG-scoped :5432. Boundaries: Internet/
WAF (managed rules), ALB (ACM identity), pod network (ClusterIP-only),
RDS (SG source). Say which are encrypted and where plaintext begins.

## E2 — CLI investigation (easy): pods Pending after a node change

*Task:* Given `FailedScheduling … Too many pods`, prove density vs requests
using two commands, then state the cheapest correct fix.
*Answer:* `describe pod` Events names the constraint; `describe node`
Allocated shows requests headroom (proving NOT requests); ENI pod cap (11 on
t3.small × nodes < 26 pods) proves density → add a node (API-managed desired),
not bigger requests. Evidence over resizing guesses.

## E3 — Validation (medium): pre-push chart review

*Task:* A PR edits `values-staging.yaml` ingress + a template. List your
validation sequence without pushing anything.
*Answer:* `helm template … --show-only templates/ingress.yaml` → diff
annotations/host/TLS against Ch. 7 rules (cert ARN region, `ssl-redirect`
port-string, host rules) → full render grep for `image:` tags (still pinned
SHAs, never `latest`) → `helm lint` → push → watch ArgoCD diff → Layer 1–3.

## E4 — Pipeline triage (medium): Release red at Trivy

*Task:* Backend scan exits 1 with 5 CVEs (2 OS, 2 minor-lib, 1 major-only-fix).
Decide the fix order and what ships when.
*Answer:* OS (`apk upgrade`, deterministic) → minor bumps + lock + suite →
major: attempt upgrade with tests, else single-CVE scoped ignore with ticket
(our Laravel 11→12 episode). Ship order follows evidence; never lower the
gate. Verify via new-tag appearance in ECR (gate proof).

## E5 — Incident (hard): 503s across the site at 02:00

*Task:* Debug in order, naming the discriminating check at each branch.
*Answer:* curl code (503 vs 504 vs 000) → DNS direct query (resolves?) → ALB
listeners/targets (listener missing? targets none?) → nodes/RDS state
(asleep? stopped? 7-day auto-wake?) → pods/ArgoCD (sync state, ESO secret
freshness) → controller logs. Our history says: check power state before
code — sleep is the commonest 503 source in this repo.

## E6 — Security review (hard): audit the secrets flow for leaks

*Task:* Find three leak vectors and their fixes.
*Answer:* (1) `kubectl exec … env`/`describe` print secrets → use file-scoped
`jsonpath` or console; (2) demo seed defaults in chat/history → rotate post-
demo, never reuse; (3) un-pushed `.env` relies on `.gitignore` + Gitleaks —
verify both exist; bonus: `secrets.create=true` must never reach real values
files (propose the CI guard).

## E7 — Cost (medium): cut 25% without touching liveness

*Task:* Using the Ch. 11 table, assemble a cut list and defend each line.
*Answer:* Acceptable: sleep discipline (behavioral, biggest), smalls, single
NAT (already), micro/1-day RDS (already). Reject with reasons: single node
(HA), dropping WAF ($5 buys the interview story), killing backups (pennies
for the DR story). Show method (Billing API + inventory), never bare numbers.

## E8 — Rebuild (hard): cluster deleted Friday, demo Monday

*Task:* Write the recovery sequence with verification gates.
*Answer:* Ch. 11 §10.1 path: state bucket intact? → tfvars review →
`apply` → outputs → secrets → Release → pin → bootstrap → seed → Layer 1–3 +
demo login. State the 2–3 h budget and the data-loss boundary (RDS snapshots
vs state vs ECR) at each step.

## Interview questions (model answers, 60–90 s spoken)

1. *"Why GitOps here?"* — No CI-held cluster creds, drift self-heal,
   revert-based rollback; ArgoCD never sees OIDC and CI never sees kubeconfig.
2. *"How do you know a deploy is safe?"* — Four independent proofs: CI tests,
   pre-push Trivy on exact bytes, immutable tag equality, post-sync Layer 1–3
   + demo login.
3. *"Tell me about an outage you debugged."* — Pick one Ch. 10 entry; narrate
   symptom→evidence→root→fix→prevention (the OIDC sub-format story is strongest).
4. *"How do you manage cost?"* — Measured table, sleep/wake with proven
   cycle, quarantine deletions, per-change bill review; numbers with methods.
5. *"What's the weakest part?"* — Honest pick: single region/AZ-limited RDS/
   no metrics pipeline — with the backlog item that fixes each.
