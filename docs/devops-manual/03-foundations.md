# Part II — Foundations this stack actually needs

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

Each section ends with **"Used in this repo:"** tying the concept to a file.
Skip nothing — later chapters assume all of it.

## 3.7 Linux: processes, users, files, network (backend/frontend images)

A container is one or more **processes** with an isolated view (namespaces)
and resource limits (cgroups). Our backend runs **supervisord** (PID 1) → it
*supervises* nginx + php-fpm children, restarting them (you saw
`exited: nginx … spawned` in Ch. 10-style logs). PID 1 duties matter: if the
entrypoint `exec`s supervisord (it does, `entrypoint.sh:66`), signals
propagate and `kubectl delete pod` terminates gracefully.

**Users:** processes have a UID. Both images run non-root (`www-data` 82,
`nginx` 101) with `runAsNonRoot` enforced by the chart. Consequence you hit:
every path the process writes (nginx pid, temp dirs, Laravel `storage/`)
must exist **and be owned** at build or runtime — the `/var/lib/nginx` and
`/tmp/nginx.pid` crashes were exactly this. Misconception: "non-root" is not
"read-only" — `readOnlyRootFilesystem: true` (frontend) additionally freezes
the whole filesystem, which is why `/tmp` needed an `emptyDir` mount.

**Filesystem layers:** image layers are read-only; the container layer is
ephemeral. Anything written outside a volume vanishes on restart — hence logs
to stdout/stderr (collected by kubelet), never to files you expect to keep.

**Networking primitives you'll use:** a *port* is just a number a process
binds; `8080` (not 80) is chosen because ports <1024 require root. DNS names
(`backend`, ClusterIP Services) resolve via the cluster DNS; an unresolvable
name at nginx **startup** kills it (the `upstream "backend"` crash) while the
same name at **request time** (via `resolver` + variable) merely fails that
request — the distinction behind the `frontend/nginx.conf` fix.

*Used in this repo:* `backend/docker/*`, `frontend/nginx*.conf`,
`securityContext` blocks in `backend.yaml`/`frontend.yaml`.

## 3.8 Git (the control plane of GitOps)

Git stores snapshots (commits) on a DAG; a branch is a movable pointer.
**Immutability parallel:** like ECR tags, a commit SHA always means the same
tree — which is why rollback-by-revert is trustworthy. Three GitOps-relevant
habits: (1) small commits with *why* in the message (this repo's history is
the audit log ArgoCD acts on); (2) never rewrite pushed `main` (ArgoCD's
`targetRevision: main` would thrash); (3) `.gitignore` is a security control —
`.env`, `*.tfstate`, `*.pem` lines are what keep secrets out of history
(Ch. 7). Misconception: "deleted from HEAD = gone" — a pushed secret needs
rotation, not just `git rm` (Gitleaks in CI exists because of this).

*Used in this repo:* every promotion is a commit to `values-staging.yaml`.

## 3.9 HTTP, DNS, TLS, reverse proxies

**HTTP:** request line + headers + optional body; status codes are contracts:
`200` ok, `301` redirect (our HTTP→HTTPS), `422` validation failure (our
login shape!), `503/504` nothing healthy upstream (your sleep-state signal).
**DNS:** hierarchical names → records (`A` addresses, `CNAME` aliases, `CAA`
which CAs may issue, `TXT` misc). You debugged all four. Key lessons: CNAME
at the *validation* name proves domain control to ACM; CAA is checked
upward from the FQDN, and a malformed value fails *closed* (`CAA_ERROR`).
**TLS:** the ALB presents the ACM certificate; browsers verify chain-to-root
+ hostname + expiry. Termination happens at the ALB — pod traffic is plain
HTTP inside the VPC (accepted trade-off, Ch. 12). ACM auto-renews *if* the
validation CNAME persists — do not delete it.
**Reverse proxy:** nginx/ALB receive client connections and open their own
upstream ones, enabling TLS termination, path routing (`/api` vs `/`),
redirects, and WAF inspection at a choke point. `X-Forwarded-*` headers carry
the original client context upstream (see both nginx confs).

*Used in this repo:* `frontend/nginx.conf`, `backend/docker/nginx/default.conf`,
`charts/.../ingress.yaml`, Cloudflare CNAME/CAA records.

## 3.10 Containers, images, registries

An **image** is a stack of content-addressed layers + config (env, user,
entrypoint). Layer caching = rebuilds reuse unchanged bottom layers (why
`COPY composer.json composer.lock` precedes `COPY .`). A **tag** is a mutable
pointer *unless the registry enforces immutability* (ECR does here) — then
tag+digest is effectively content-addressed, and scanning it means something.
`docker push` uploads missing layers; `pull` reverses it. **Registries**
authenticate separately from clouds (ECR login via OIDC-derived creds).
Image-pull failures (`ImagePullBackOff`) are auth, network, or name errors —
never "the app crashed" (Ch. 10). Misconception: rebuilding "the same"
Dockerfile gives the same bytes — base-image snapshots and `apk` indexes move,
so `sha-xxx` tags plus rebuild-on-push are what make builds reproducible
*enough*.

*Used in this repo:* both Dockerfiles, `ecr.tf`, `release.yml` build steps.

## 3.11 CI/CD and deployment strategies

CI = build+test every change fast (ours: no AWS, <5 min). CD here = *delivery*
to the registry + GitOps *deployment* by ArgoCD (as opposed to push-based
`kubectl apply` from CI). Our strategy is **RollingUpdate** (one pod at a time,
PDB-guarded), the default and the right one at this scale; blue-green/canary
need traffic-splitting machinery this project correctly skips. Promotion =
human pins a scanned tag; the "approval gate" is a git commit, reviewable and
revertable. Misconception: "green CI means safe to deploy" — CI proves code
correctness; the Trivy gate + tag pinning prove *artifact* safety. Both are
required, neither suffices.

*Used in this repo:* `.github/workflows/*`, `values-staging.yaml` tags.

## 3.12 Cloud, IAM, shared responsibility

AWS owns the physical/DC/hypervisor layers (**shared responsibility**); you
own everything you configure — SG rules, IAM policies, encryption flags, key
rotation. **IAM** evaluates *who* (principal) × *what* (action/resource) ×
*conditions*. Two mechanisms in this repo: **IRSA** (a K8s ServiceAccount
annotated with a role ARN gets short-lived creds via the cluster OIDC
provider — ESO reads Secrets Manager this way) and **GitHub OIDC** (Actions
mints a JWT; `AssumeRoleWithWebIdentity` succeeds only if `aud` *and* the
`sub` pattern match — the numeric-`@id` format broke us in Ch. 10). Least
privilege = scope each role to its two resources (ECR push: two repos;
ESO: `secureops/*/database+app` reads). Misconception: "the node role covers
pods" — modern EKS gives pods *their own* identities; node role is for
kubelet/ECR-pull only.

*Used in this repo:* `iam-github-oidc.tf`, `eso-irsa.tf`, `eks.tf:48`,
`clustersecretstore.yaml`.

## 3.13 IaC: desired state, dependencies, drift

Terraform compares **desired** (`.tf` + `.tfvars`) → **actual** (AWS) via
**state** (S3 + DynamoDB lock), then converges. `plan` is a dry-run diff;
`apply` executes it. **Dependencies** (`depends_on`, implicit references)
order creation — wrong order was the LB-webhook race. **Drift** = actual
diverging without Terraform (console edits, autoscalers, our API-managed node
count). Reconcile by importing or re-applying, never by hand-editing state.
`lifecycle ignore_changes` (node `desired_size`) is *declared* drift —
powerful, document it where used. Remote state + locking is what makes IaC
team-safe; `terraform.tfstate` contains secrets (RDS password!), hence S3
encryption + never-in-git.

*Used in this repo:* all of `infra/terraform/`, Ch. 11 teardown ordering.

## 3.14 Kubernetes (only what this chart uses)

**Pod** (one+ containers sharing network/storage), **Deployment** (declares
replicas + rolling strategy; owns ReplicaSets), **Service** (stable virtual IP
+ DNS for shifting pods), **Ingress** (L7 rules → Services; implemented here
by the ALB Controller, which *provisions AWS resources* from the object),
**ConfigMap/Secret** (env/config injection; Secrets are base64, not
encrypted — ESO populates ours), **HPA** (replicas from CPU metrics),
**PDB** (protects minimum availability during voluntary disruption),
**Job** (run-to-completion, ours hook-deleted), **ServiceAccount** (pod
identity for IRSA), **probes** (liveness = restart me; readiness = route to
me; ours: `/up` vs `/api/v1/health`). Scheduling constraints that bit us:
per-node pod caps (ENI limits), requests vs limits, affinity/zone spread.

*Used in this repo:* `charts/secureops/templates/*`.

## 3.15 Observability: signals and the health ladder

Four distinct rungs — never conflate them: (1) **process running** (supervisor
spawned it), (2) **container healthy** (probes pass), (3) **endpoint
responding** (curl 200), (4) **service behaving** (login returns token, data
correct). Our incidents climbed this ladder both directions (Ch. 8/10).
**Metrics** (numbers over time: CPU, 5xx counts → alarms), **logs** (event
streams: `kubectl logs`, supervisor/nginx/app), **traces** (absent here —
stated gap, not a hidden feature). Health endpoints are load-bearing API:
readiness gates traffic, liveness gates restarts; swapping them causes
restart-storms or black-holed traffic — ours are correctly split.

*Used in this repo:* probes in `backend.yaml`/`frontend.yaml`, `alarms.tf`,
`ops/wake.sh` Layer-3 checks.
