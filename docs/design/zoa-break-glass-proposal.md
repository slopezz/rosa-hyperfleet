# ZOA Break-Glass — Feature Proposal

**Status:** Draft for review (HyperFleet / ZOA)  
**Audience:** Engineering, security, SRE  
**Repos:** `rosa-hyperfleet-zoa` (API, CLI, worker), `rosa-hyperfleet` (Terraform, observability)

## 1. Summary

Break-glass (BG) grants **time-boxed, scoped `kubectl` and/or `aws` CLI access** from inside an **existing ZOA Boundary** session. It is not a laptop path and not a replacement for Trusted Actions.

**Product rules (existing):**

- Entry is always `zoa session start` → ECS Exec → boundary container (`ZOA_API_URL` set).
- Every BG use should drive a follow-up TA so the same operation can be automated later (README policy).

**Architect decision (lifecycle):** two independent clocks.

| Phase                                   | Expiration                                                                                                                                                                                                                  |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Pending request** (awaiting approval) | Set at create: **`requestExpiresAt = createdAt + pendingTTL`**. If approval does not complete before this time, the request becomes **`expired`** — it cannot be approved, connected, or revived (must open a new request). |
| **Approved grant**                      | Set on approve/reject decision: **`grantExpiresAt = decisionAt + 4h`** (configurable; only when `status=approved`). Credential TTLs capped by remaining time until `grantExpiresAt`. No separate “activate” clock.          |

**`pendingTTL`** is environment/config driven (TBD; e.g. shorter in prod for manual approval, longer in dev if approvers are sparse). Distinct from the 4h post-approve window.

**Approval:** Ship with **auto-approve** in dev/ephemeral; same code paths as **manual** approve/reject (reuse approval pattern from TA manual workflow).

**Operator UX:** SRE does **not** hand-build kubeconfig or `aws configure`. After approval, **`zoa breakglass use <request-id>`** provisions (if needed), writes **secret-free** files under `~/.config/zoa/breakglass/<requestId>/`, and activates via **bashrc** (silent env + **PS1** break-glass line for kube and/or aws). No `export` spam, no `env` / public `credential` commands. Stock **`kubectl` / `aws`**. See §5.6 and §7.1.

---

## 2. Goals and non-goals

### Goals

- Scoped emergency access: **`kube-read` / `kube-write` / `aws-read` / `aws-write`** (same vocabulary as TA `Type`) — see §5.8.
- **Attribution:** human `operator` (identity bridge), ZOA `boundary_session_id`, BG `grant_id`, ECS `task_id`, CloudTrail / K8s audit correlation.
- **Task binding:** only the **boundary ECS task** that created the request may call `connect` and receive credentials (API-enforced; not STS magic).
- Prepare for **approval workflow** without a second domain model.
- Reuse **HANDLER_MODE=api** Lambda, Worker reconciler, DynamoDB, EMF metrics, audit table patterns.

### Non-goals (initial slice)

- Laptop SAML console login (`rh-aws-saml-login`) — out of scope inside boundary; BG AWS console uses **STS federation from the grant** (see §5.8).
- BG from laptop (Access Lambda) except **approve/reject** (and optional list/history for approvers).
- Full **`cluster-admin`** / **`AdministratorAccess`** — use **elevated** scopes that are “almost admin” with explicit denies (secrets, IAM, org, destructive defaults).
- Per-task IAM role for boundary (shared task role remains).
- **Operator-initiated revoke** (v1 ends access only via `grantExpiresAt` + Worker cleanup; STS/kube tokens run until their natural expiry — document bearer limits).

---

## 3. Architecture fit

```text
Laptop                    Boundary (ECS)                 API Lambda (VPC)
  |                              |                              |
  | session start (Access)       | zoa breakglass request       |
  |                              | zoa breakglass connect ----->| identity bridge
  | zoa approve <id> (Access)    |                              | AssumeRole (AWS) / K8s API (kube)
  |                              |<----- one-time material -----| write SA + token / STS creds
  |                              | kubectl / aws (native)       |
```

- **Discovery / sessions:** unchanged (Access Lambda, Central SSM).
- **BG request / connect:** **API Lambda** only (SigV4 boundary task role), same as `zoa run`.
- **Approve / reject:** **Access Lambda** (invoker role, no boundary required) and **API Lambda** (approver inside boundary if desired) — same handlers as TA approval stubs (`/api/v0/approve/{id}`, `/api/v0/reject/{id}`), extended to BG request IDs.
- **Provisioning:** API Lambda execution role already has **EKS access entry** and creates ephemeral RBAC for TAs; BG reuses that machinery with **dedicated SA per grant**.
- **AWS BG roles:** Terraform precreates IAM roles; **only API Lambda execution role** may `sts:AssumeRole` (remove `breakglass_role_arns` from boundary **task** role in Terraform when BG ships).

---

## 4. Domain model

**Storage choice:** one DynamoDB item per break-glass request (same pattern as `executions` — single row, lifecycle via `status` and timestamp fields). No separate “grant” table; approval and grant metadata live on the same item after approve. The API Lambda (and only the API Lambda for mutating BG state) writes this table; Access Lambda approve/reject calls API or writes via shared store — prefer **one writer path in API** with approve routed through API self-invoke or direct DynamoDB from Access only if we already do that for TAs (default: **API owns writes**).

**ID convention (aligned with sessions / executions):**

| Layer            | Break-glass                                                                         | Sessions                    | TA executions                                  |
| ---------------- | ----------------------------------------------------------------------------------- | --------------------------- | ---------------------------------------------- |
| **DynamoDB PK**  | `requestId` = **UUID v4** (no prefix)                                               | `sessionId` = UUID          | `executionId` = UUID                           |
| **Boundary CLI** | Raw UUID                                                                            | Raw UUID (`ZOA_SESSION_ID`) | Raw UUID on `zoa get`                          |
| **Laptop CLI**   | **`deployment/<uuid>`** on approve/reject (compound routing to Access → target API) | Same compound pattern       | Approve TBD: compound or `--deployment` + UUID |

- **No `bgreq-` (or similar) in DynamoDB.** Type is implied by **table** (`zoa-breakglass` vs `executions`) and by **command** (`zoa breakglass …` vs `zoa run` / `zoa get`).
- **Human “TA vs BG”:** optional in UX only — e.g. `zoa breakglass list -o json` includes `"kind": "breakglass"` and `scope`; pending-approval inbox (future) is a separate view. Do **not** encode type in the stored id.
- **Naming elsewhere (K8s, STS, labels):** always the **full `requestId` UUID** (e.g. SA `zoa-bg-<requestId>`, label `zoa.openshift.io/request-id`). No shortened ids in Dynamo or in the API.

| Logical entity            | DynamoDB                                 |
| ------------------------- | ---------------------------------------- |
| Request + grant lifecycle | **One item** keyed by `requestId` (UUID) |

**Laptop `approve` / `reject`:** path or arg accepts **compound** `deployment/<requestId>` (mirror `zoa session terminate`). Access resolves deployment SSM → regional API → `GetItem` on break-glass table. For TA manual approval, same route: try `executions` then `zoa-breakglass` (or reverse) by compound deployment scope — **never** rely on a string prefix in the UUID.

**Status** — reuse **`store.Status`** values where they match executions (`pending_approval`, `approved`, `rejected`, `failed`). Add **`expired`** for BG pending/grant time-boxing (executions use `timed_out` for a different concept).

```text
pending_approval → approved  (until grantExpiresAt; lazy K8s on first use/connect)
                ↘ rejected
                ↘ expired    (pending past requestExpiresAt, or approved past grantExpiresAt)
                ↘ failed     (provision/cleanup error)
```

No `provisioning` / `active` statuses — provision is a **side effect** of `connect` while `status=approved`, same idea as “approved TA” before `dispatched`. **Connect** detail events live in the **audit** table (`breakglass_connect`), not extra Dynamo columns.

**Pending expiry rules:**

- On **create**, persist `requestExpiresAt` (never extended).
- **`approve` / `reject`** after `requestExpiresAt`: **409** (`BG_REQUEST_EXPIRED`).
- **Worker** expires pending (reaper style) and approved past `grantExpiresAt` (see §8).
- Expired / rejected rows **never** issue credentials.

**Approval decision fields** (one outcome block, not parallel approve/reject columns):

Executions today only have `approvedBy` ([`pkg/store/types.go`](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/pkg/store/types.go)). For BG, use a minimal **decision** trio set once when leaving `pending_approval`:

| Field          | Approve                     | Reject                 |
| -------------- | --------------------------- | ---------------------- |
| `decisionAt`   | RFC3339Nano                 | RFC3339Nano            |
| `decisionBy`   | approver username or `auto` | approver username      |
| `decisionNote` | optional comment            | optional reject reason |

`status` is the source of truth (`approved` vs `rejected`). No `approvedAt` + `rejectedAt` pairs. On approve only: also set `grantExpiresAt = decisionAt + grantDuration`. TA manual approval can adopt the same shape later.

### 4.1 DynamoDB table `{regionalId}-zoa-breakglass`

New table in `terraform/modules/zoa/dynamodb.tf` (sibling to `executions`, `audit`, `boundary-sessions`). Worker env: `BREAKGLASS_TABLE` on **API + Worker** Lambdas (same table, same region/account as executions).

**Primary key:** `requestId` (UUID) — same role as `executionId` / `sessionId`.

**Item shape** — keep parity with **executions** + **sessions**; avoid BG-only optional sprawl.

**Derived cluster objects (same idea as TA):** TAs use one prefix everywhere: ServiceAccount / Role(s) / Binding(s) named **`zoa-exec-<executionId>`** (see `executor.go` / `resources.go`); labels use `zoa.openshift.io/execution-id=<executionId>`. Break-glass: **`zoa-bg-<requestId>`** with the same shape; add **`zoa.openshift.io/request-id=<requestId>`** in `pkg/labels` (parallel to `KeyExecutionID`). **Execution / break-glass rows do not store resource names**; cleanup derives names from the UUID.

**AWS (break-glass):** no per-request AWS objects to GC — API **`AssumeRole`** into pre-Terraform roles; only **STS session credentials** exist (TTL capped). Same as aws-api TAs today (no IAM entity GC). Standing break-glass roles stay in Terraform.

**Attribution ids on the row (session pattern):** store **`taskId`** and **`sessionId`** like sessions/executions — bridge lookup, connect binding, forensics. Optional **`taskArn`** only if we later mirror sessions; **not required v1**.

| Attribute                                  | Set when                 | Notes                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------ | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `requestId`                                | create                   | PK                                                                                                                                                                                                                                                                                                         |
| `status`                                   | every transition         | Shared enum with executions where possible                                                                                                                                                                                                                                                                 |
| `scope`                                    | create                   | e.g. `kube-read` (`aws` vs `kube` inferred from scope prefix)                                                                                                                                                                                                                                              |
| `targetCluster`                            | create                   | Same as executions / sessions                                                                                                                                                                                                                                                                              |
| `accountId`                                | create                   |                                                                                                                                                                                                                                                                                                            |
| `operator`                                 | create                   | Identity bridge                                                                                                                                                                                                                                                                                            |
| `signerARN`                                | create                   | Task role ARN                                                                                                                                                                                                                                                                                              |
| `sessionId`                                | create                   | Boundary session UUID (`sessionId` in Dynamo, not a BG-specific name)                                                                                                                                                                                                                                      |
| `taskId`                                   | create                   | Connect binding; GSI pattern like sessions **`task-id-index`** only if we add it — **v1: no extra GSI**; store `taskId` on row like sessions                                                                                                                                                               |
| `reason`                                   | create                   | Justification (INC/Jira); not reused for reject text                                                                                                                                                                                                                                                       |
| `approval`                                 | create                   | Snapshot of resolved workflow tier: `auto` \| `manual` \| `strict` (from scope + config at create)                                                                                                                                                                                                         |
| `minApprovers`                             | create                   | From `Authorization.MinApprovers` after merge                                                                                                                                                                                                                                                              |
| `requireDecisionNote`                      | create                   | bool snapshot                                                                                                                                                                                                                                                                                              |
| `createdAt`                                | create                   | RFC3339Nano                                                                                                                                                                                                                                                                                                |
| `requestExpiresAt`                         | create                   | Pending approval deadline                                                                                                                                                                                                                                                                                  |
| `grantExpiresAt`                           | approve                  | Absent when `rejected`                                                                                                                                                                                                                                                                                     |
| `decisionAt`, `decisionBy`, `decisionNote` | approve or reject        | See table above; `omitempty` until decided                                                                                                                                                                                                                                                                 |
| `failedReason`                             | `failed`                 | Mirror `stopReason` on sessions (`omitempty`)                                                                                                                                                                                                                                                              |
| `revision`                                 | create                   | **ZOA git commit** of the Lambda that created the row — same as `Execution.revision` (`dispatch.go` → `version.GitCommit`). **Also add `revision` on boundary `Session` at `session_start`** (Access Lambda build) so sessions match executions/break-glass for support forensics. Not optimistic locking. |
| `dateBucket`, `targetStatusKey`, `ttl`     | create + each transition | Listing + worker queries (below)                                                                                                                                                                                                                                                                           |

**Never stored:** STS keys, kube tokens, kubeconfig bodies, K8s/IAM resource **names**, assumed-role ARNs, connect timestamps.

**`targetStatusKey`** (same GSI names as executions — [`storage.md`](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/docs/architecture/storage.md)):

| `status`           | `targetStatusKey`                                      |
| ------------------ | ------------------------------------------------------ |
| `pending_approval` | `pending_approval#<requestExpiresAt>`                  |
| `approved`         | `approved#<grantExpiresAt>`                            |
| Terminal           | `rejected#<decisionAt>`, `expired#<ts>`, `failed#<ts>` |

**GSIs (two only, same as executions):** `target-status-index` (worker per `TARGET_CLUSTER`), `date-bucket-index` (`zoa breakglass list` / history with `--since`, filter like `zoa runs`).

**Worker:** existing 5m tick — `pkg/scheduler/breakglass.go` in the **same package** as reaper/GC; no new Lambda.

1. **Expire pending:** `pending_approval#` past `requestExpiresAt` → `expired`.
2. **Expire grants:** `approved#` past `grantExpiresAt` → `expired`, delete cluster objects by label `zoa.openshift.io/request-id=<requestId>` (idempotent; no per-row K8s name fields).

API writes create / approve / reject / connect synchronously. Worker: expiry + labeled K8s cleanup only.

**Cross-reference audit:** lifecycle detail in **`audit`** (`breakglass_request`, `breakglass_approve`, `breakglass_connect`, …) with `requestId` — same pattern as `executionId` on TA audit rows.

### 4.2 Code layout (not a bolt-on)

Mirror **existing package boundaries** so “where do I look?” matches TA/sessions today (`pkg/actions` ↔ `pkg/scopes`, `pkg/api/dispatch.go` ↔ `pkg/api/breakglass.go`, `zoa runs` ↔ `zoa breakglass requests`).

**Repo map (ZOA monorepo)**

| Concern                       | Established pattern                                                                | Break-glass (same shape)                                                                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Catalog types + registry**  | `pkg/actions/types.go`, `registry.go`, `getresource.go`, …                         | **`pkg/scopes/`** — sibling package, **not** nested under breakglass. One file per scope id: `kube_read.go` → scope **`kube-read`** (hyphen in id, underscore in filename, like `getresource.go` ↔ `get_resource`).          |
| **Catalog conformance**       | `pkg/actions/conformance_test.go`, `rbac_validator.go`                             | **`pkg/scopes/conformance_test.go`**, **`pkg/scopes/rbac_validator.go`** (reuse validators where possible).                                                                                                                  |
| **Persistence**               | `pkg/store/execution.go`, `session.go`                                             | **`pkg/store/breakglass.go`** — `BreakglassRequest`, `BreakglassStore`, transitions like `Execution`.                                                                                                                        |
| **HTTP path constants**       | `pkg/api/paths.go` — `PathTrustedActions`, `PathSessions`, …                       | **Extend `paths.go`:** `PathBreakglass`, `PathBreakglassScopes`, `PathBreakglassRequests` (§6).                                                                                                                              |
| **HTTP handlers**             | TA: list/describe in `router.go`; dispatch in `dispatch.go`. Sessions: `access.go` | **`pkg/api/breakglass.go`** — create/get/list/connect + scope list/describe handlers; **`router.go`** wires routes only (no handler body growth).                                                                            |
| **Approve/reject**            | `PathApprove` / `PathReject` in `access.go`                                        | Same routes; handler resolves UUID → **executions** or **breakglass** store.                                                                                                                                                 |
| **Kube RBAC materialization** | `pkg/executor/resources.go` — `zoa-exec-<executionId>`                             | **`pkg/executor/breakglass_resources.go`** — `zoa-bg-<requestId>`, labels `zoa.openshift.io/request-id`; **`CleanupBreakglass`** beside `CleanupExecution`.                                                                  |
| **AWS AssumeRole**            | `pkg/executor/executor.go` `buildAWSParams`                                        | **`pkg/executor/breakglass_aws.go`** — `AssumeBreakglassRole(scope, requestId, cfg)`; env from **`pkg/config`**.                                                                                                             |
| **Worker expiry/GC**          | `pkg/scheduler/gc.go`, `reaper.go`                                                 | **`pkg/scheduler/breakglass.go`** in same package/tick.                                                                                                                                                                      |
| **Route metrics templates**   | `pkg/metrics/routes.go`                                                            | Add **`/api/v0/breakglass/scopes/{id}`**, **`…/requests/{id}/connect`**, etc.                                                                                                                                                |
| **Audit action strings**      | `pkg/api/audit_actions.go`                                                         | Add `breakglass_*` constants next to existing audit types.                                                                                                                                                                   |
| **CLI group**                 | `internal/cli/session.go`, `run.go`                                                | **`internal/cli/breakglass.go`** — Cobra group; subcommands split like session: **`breakglass_scopes.go`** (mirror `actions.go`), **`breakglass_requests.go`** (mirror `runs.go` naming: list/history against **requests**). |
| **Offline catalog**           | `internal/cli/actioncatalog/`                                                      | **`internal/cli/scopecatalog/`** — embed `pkg/scopes` for `--offline`.                                                                                                                                                       |
| **Shell completion**          | `internal/cli/actionregistry.go`                                                   | **`internal/cli/scoperegistry.go`**.                                                                                                                                                                                         |
| **Hidden cred helpers**       | —                                                                                  | **`cmd/zoa-breakglass-cred/`** or thin `internal/cli/breakglass_cred.go` (**hidden**, no `cobra` help).                                                                                                                      |
| **Boundary PS1**              | `boundary/home-sre/.bashrc.d/10-zoa-prompt.bashrc`                                 | **`11-zoa-breakglass-prompt.bashrc`** (§7.1).                                                                                                                                                                                |
| **IAM roles (AWS)**           | `terraform/modules/zoa-lambda/main.tf` `zoa_aws_read` / `write`                    | **`terraform/modules/zoa-lambda/breakglass_iam.tf`** — `zoa_bg_aws_*` roles + policies; env vars on API Lambda like `AWS_READ_ROLE_ARN`.                                                                                     |
| **Config env**                | `pkg/config/config.go`                                                             | `BREAKGLASS_REQUESTS_TABLE`, `BREAKGLASS_AWS_*_ROLE_ARN` (or JSON map).                                                                                                                                                      |

**Naming rule:** HTTP resources use **kebab** plural segments (`/breakglass/requests`); Go packages use **short nouns** (`scopes`, `store`); scope **ids** use **hyphens**; scope **files** use **underscores**.

No parallel “BG approval domain” beyond the second Dynamo table.

---

## 5. Security and attribution

### 5.1 Boundary-only invoke

- BG HTTP routes on API Function URL: caller must be boundary **task role** (existing resource policy).
- **Request** records `taskId` and `sessionId` from identity bridge (same field names as executions).

### 5.2 Task binding on `connect`

- `connect` allowed only if: `status=approved`, `now < grantExpiresAt`, `taskId` **==** caller task id, `operator` matches (optional: same `sessionId`).
- Prevents another SRE’s concurrent boundary task from stealing credentials even with shared task role.

### 5.3 Kubernetes

- On connect (first time): API Lambda creates in target cluster:
  - `ServiceAccount` **`zoa-bg-<requestId>`** (full UUID; unique per request).
  - Role/Binding per scope template (deterministic names including `requestId`).
  - Labels: `zoa.openshift.io/request-id`, `zoa.openshift.io/operator`, `zoa.openshift.io/session-id` (values = full UUIDs / operator string).
- Token via **TokenRequest** with `expirationSeconds = min(remaining grant time, 3600)` (refresh on each plugin call while grant valid).
- ZOA writes kubeconfig with **`user.exec`** pointing at a **hidden entrypoint** (e.g. `/usr/local/lib/zoa/breakglass-kube-cred` or `zoa` hidden subcommand **omitted from `zoa --help`**) — not a documented `zoa breakglass credential` command.
- **`use` does not print paths or exports**; it updates `~/.config/zoa/breakglass/active` and relies on boundary **`bashrc.d`** to set `KUBECONFIG` / `AWS_PROFILE` for the session (same pattern as other boundary env wiring).
- **Audit:** K8s user `system:serviceaccount:<ns>:zoa-bg-<requestId>` → row → operator; each plugin invocation → `breakglass_credential` audit (rate-limited).

**Not** using shared boundary task role + `aws eks get-token` alone (that would not yield per-grant SA in audit).

### 5.4 AWS

- API Lambda `AssumeRole` into Terraform role for scope (from env/config per scope).
- `RoleSessionName`: `bg-<requestId>` (UUID fits STS 64-char limit; operator in session tags / `SourceIdentity`).
- `SourceIdentity`: operator username when bridge hit; omit if degraded (BG admin scopes should **fail closed** on degraded identity — policy).
- Session tags (when supported on role trust): `ZOARequestId`, `ZOAOperator`, `ZOABoundaryTask`, `ZOAScope`, `ZOAEnvironment`.
- CLI writes a **fragment** under `~/.config/zoa/breakglass/<requestId>/` with profile `zoa-bg-<requestId>` and **`credential_process`** aimed at the same class of **hidden helper** (no static keys on disk).
- **DurationSeconds:** `min(remaining grant window, role MaxSessionDuration)` per AssumeRole response.

### 5.5 STS bearer caveat

Credentials may still be copied if an operator deliberately runs the credential helper or intercepts plugin I/O; controls are short TTL, narrow scope, task-bound **issuance**, per-refresh audit, and operator guide. No design eliminates a malicious insider inside the boundary.

### 5.6 Credential exposure (ECS Exec / CloudWatch)

Boundary **Exec PTY transcripts** land in CloudWatch ([session logging](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/docs/boundary/session-logging.md)). Anything echoed in the shell (including `cat` of kubeconfig, `export AWS_*`, or manual runs of the credential helper) can be replayed.

**v1 approach (recommended):**

| Approach                                                    | Verdict                                                                                                                                                                        |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Static token / keys in files under `$HOME` (owned by `sre`) | **Avoid** — trivial `cat`/`vim` exfil in logged session.                                                                                                                       |
| Directory writable only by ZOA, unreadable by `sre`         | **Not practical** on Fargate without a setuid root helper — high complexity, weak guarantee (`sre` can still invoke the helper or use `kubectl`/`aws` and leak plugin output). |
| **No secrets on disk** — exec plugin + `credential_process` | **Default** — on-disk artifacts are grant metadata and plugin command lines only.                                                                                              |
| Secrets only in parent process memory                       | **Partial** — plugins still emit JSON to stdout for `kubectl`/`aws`; avoid putting secrets in **environment** variables (visible in `/proc` and some tooling).                 |

**`use` behavior:** provision cluster/IAM objects; write pointer configs; update **`~/.config/zoa/breakglass/active`** (see §7.1); bashrc applies env **silently**. **Stdout:** optional single line **or rely on prompt only** (prefer **prompt-only** feedback so the PTY stays minimal). **Stderr:** errors only. No credential bodies, no `export`, no paths.

**No `zoa breakglass env`**, **no public `credential` subcommand** — anything `kubectl` / `aws` invoke via exec / `credential_process` is **implementation detail** (hidden binary or cobra command), not operator UX.

**Operator guide:** after `zoa breakglass use <request-id>`, the **prompt** shows active kube/aws BG; run stock `kubectl` / `aws`; use `zoa breakglass status` and audit for detail; do not `cat` breakglass config.

### 5.7 Approval

- Auto-approve: `decisionBy = "auto"`, `status = approved`, set `grantExpiresAt`.
- Manual: pending until `zoa approve <deployment>/<requestId>` / `zoa reject …` from laptop (Access → API), or boundary-local flows that only use the raw UUID.
- Requester ≠ approver enforced when manual (403).

**Per-scope workflow lives in scope metadata** (§5.7.1) — same idea as TA `Authorization.Approval` in each `pkg/actions/*.go`, but richer because a break-glass scope is a **standing privilege class**, not a single command.

#### 5.7.1 Approval workflow metadata (per scope)

Each scope file in **`pkg/scopes`** declares **`Authorization`** (workflow defaults). **Higher-risk scopes declare stricter workflows**; the API enforces whatever was **snapshotted onto the Dynamo row at create time** (so in-flight requests do not change when config or code deploys mid-flight).

**Go shape (parallel to `actions.AuthorizationConfig`, extended):**

```go
// pkg/scopes/types.go
type AuthorizationConfig struct {
    // Workflow tier — stable string for metrics, audit, describe output.
    // v1 codes: "auto", "manual", "strict"
    // Future TA parity: "1-peer", "2-peers", "2-seniors" (see pkg/actions/TEMPLATE.go.example)
    Approval string `json:"approval"`

    // Environments where Approval may downgrade to auto (e.g. ephemeral only for kube-read).
    // Empty = never auto from env alone; still subject to deployment override.
    AutoApproveEnvironments []string `json:"auto_approve_environments,omitempty"`

    RequesterCannotApprove bool `json:"requester_cannot_approve"` // default true for manual+
    MinApprovers         int    `json:"min_approvers"`          // 1 or 2 (v1: 1; strict: 2)
    RequireDecisionNote  bool   `json:"require_decision_note"`  // approve comment mandatory
    RequireRejectReason  bool   `json:"require_reject_reason"` // mirror zoa reject --reason

    DefaultGrantHours    int `json:"default_grant_hours"`
    DefaultPendingHours  int `json:"default_pending_hours"` // requestExpiresAt window
    PageOnRequest        bool `json:"page_on_request,omitempty"` // elevated: optional paging hook
}
```

**Example in `kube_read.go` / `kube_elevated.go`:**

```go
Authorization: AuthorizationConfig{
    Approval:                "auto", // or "manual" / "strict"
    AutoApproveEnvironments: []string{"ephemeral"},
    RequesterCannotApprove:  false,  // only meaningful when Approval != auto
    MinApprovers:            1,
    RequireDecisionNote:     false,
    DefaultGrantHours:       4,
    DefaultPendingHours:     24,
},
// kube-elevated:
Authorization: AuthorizationConfig{
    Approval:                "strict",
    RequesterCannotApprove:  true,
    MinApprovers:            2, // v2: second approver; v1 may ship MinApprovers=1 + RequireDecisionNote until dual-approve exists
    RequireDecisionNote:     true,
    DefaultGrantHours:       1,
    DefaultPendingHours:     4,
    PageOnRequest:           true,
},
```

**Resolution order at `POST …/breakglass/requests`** (deterministic, testable):

1. **`scopes.Get(scope).Authorization`** — code defaults from the scope’s `.go` file.
2. **Deployment override** — `config/` / Lambda env `BREAKGLASS_SCOPE_OVERRIDES` or `breakglass_scopes.<id>.approval` (§9) may **tighten only**, never loosen past code maximum in prod (e.g. code says `strict`, config cannot force `auto` in `stage`/`production`).
3. **Environment** — if merged workflow allows `auto` and current deployment ∈ `AutoApproveEnvironments`, run auto-approve path.
4. **Persist snapshot** on the item: `approval` (string), `minApprovers`, `requireDecisionNote`, `requestExpiresAt`, `grantDurationSeconds` (from `default_grant_hours` when approved) — approver UI and `zoa breakglass describe` read the **catalog**; the **request row** holds what applies to **this** grant.

**Workflow tiers (each scope picks one base tier; tiers escalate with risk):**

| Tier (`approval`) | Typical scopes                                            | Operator / approver experience                                                                                                                                                                      |
| ----------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`auto`**        | `kube-read` in ephemeral                                  | Immediate `approved`; audit `decisionBy=auto`.                                                                                                                                                      |
| **`manual`**      | `kube-read` stage+, `kube-write`, `aws-read`, `aws-write` | One approver; requester ≠ approver; optional comment on approve.                                                                                                                                    |
| **`strict`**      | `kube-elevated`, `aws-elevated`                           | Mandatory `decisionNote` on approve; **two approvers** when engine supports it (v1 may require note + single on-call lead); shorter pending + grant TTL; optional page; **never** auto outside dev. |

**Making a scope harder to approve later** does not require new code paths — change **metadata** in `kube_write.go` and/or **tighten override** in `config/stage/…yaml` → re-render deploy. `zoa breakglass describe <scope>` and `GET …/scopes/{id}` show the current workflow so approvers know rules before they get paged.

**Conformance** (`pkg/scopes/conformance_test.go`): every registered scope must set valid `Approval`, `DefaultGrantHours > 0`, `elevated` scopes must use `strict` and `DefaultGrantHours <= 2`, `read` scopes must not use `MinApprovers > 1` unless `strict`, etc.

**TA convergence (future):** same `approval` string vocabulary as TA TEMPLATE (`1-peer`, `2-peers`) so one approval engine can serve `zoa run` and `zoa breakglass request`.

### 5.8 Scopes catalog (kube + AWS)

Design principles (industry-aligned, ZOA-specific):

- **Three permission tiers** — **`read`** (tight observe), **`write`** (surgical mutate: **narrow Allow lists** + **heavy explicit Deny** in IAM), **`elevated`** (**near-admin operational access**: **broad Allow** like admin/PowerUser, **small hard Deny** set for exfiltration and escalation only). No scope id named `*-admin`; elevated is the admin surrogate, not literal `cluster-admin` / `AdministratorAccess` attachments.
- **Read must not read secrets** — AWS: explicit **`Deny`** on `secretsmanager:Get*`, `ssm:GetParameter*` for `SecureString` paths (and customer secret prefixes), tight S3 `GetObject` (no customer data buckets; TA artifact path only if needed for parity). K8s: **no `secrets` get/list** (re-use HCP namespace blocks from [`get_secret`](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/pkg/actions/getsecret.go) — `cluster-*`, sensitive names).
- **Separate from TA IAM** — do **not** reuse `*-zoa-aws-read` / `*-zoa-aws-write` used for async TA Jobs ([`terraform/modules/zoa-lambda/main.tf`](https://github.com/openshift-online/rosa-seaplane/blob/main/terraform/modules/zoa-lambda/main.tf)). BG roles are sibling resources with **API Lambda-only trust**, BG session tags, and policies tuned for **interactive** investigation (not Job + S3 upload).
- **Kube RBAC** — compiled in **`pkg/scopes`** (§4.2): API Lambda applies templates on `use`. **AWS IAM** — **Terraform only** (`breakglass_iam.tf`); Go holds **role key → env ARN**, not policy JSON.
- **Approval policy** — declared **per scope** in `Authorization` metadata (§5.7.1); config may **tighten** per environment, not bypass code max in prod.

#### 5.8.1 Scope registry — one Go file per scope (how this differs from TA AWS)

**Trusted Actions (reference today):**

| Plane        | Where permissions live                                                                                  | Where the runtime picks credentials                                                                                                                                                                                                                                                                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **kube-api** | **Each TA `.go` file** — `ActionMetadata.RBAC` (`pkg/actions/getresource.go`, etc.)                     | `pkg/executor` builds Role/Binding from that metadata (`zoa-exec-<executionId>`).                                                                                                                                                                                                                                                                                                                |
| **aws-api**  | **Terraform** — `aws_iam_role.zoa_aws_read` / `zoa_aws_write` in `terraform/modules/zoa-lambda/main.tf` | **Not in each TA file.** Each aws TA only sets `Scope: "aws-api"` and `Type: "read"` \| `"write"` (`pkg/actions/awsvpc.go`). **`pkg/executor/executor.go`** does `roleARN := awsReadRoleARN; if meta.Type == "write" { roleARN = awsWriteRoleARN }`. ARNs are **Lambda env** `AWS_READ_ROLE_ARN` / `AWS_WRITE_ROLE_ARN` from `pkg/config/config.go` (set by Terraform on the API/worker Lambda). |

Break-glass has **no per-action catalog** — the **scope id** (`kube-read`, `aws-write`, …) is the unit of authorization. Ship **one Go file per scope**, mirroring kube TA files (RBAC in code) and aws TA _wiring_ (role ARN from env), not aws TA _metadata_ (no IAM in every action file).

**Package layout (`pkg/scopes/` — parallel to `pkg/actions/`):**

```
pkg/scopes/
  types.go             # ScopeMetadata (describe/catalog), ScopeDefinition (authz), plane, tier
  registry.go          # Register, Get, List, ListCatalog — same init() pattern as pkg/actions/registry.go
  aws_rolekey.go         # AwsRoleKey enum + RoleARN(cfg) lookup
  rbac_validator.go    # optional: share/pkg/actions/rbac_validator patterns
  conformance_test.go
  kube_read_rc.go          # KubeReadRules(rc) — scope kube-read + get_resource on RC
  kube_read_mc.go          # KubeReadRules(mc)
  kube_write_rc.go
  kube_write_mc.go
  kube_elevated_rc.go      # phase 2
  kube_elevated_mc.go
  aws_read.go            # scope id aws-read; AwsRoleKey only (+ Describe bullets)
  aws_write.go
  aws_elevated.go
```

**Per-file contract (example shape, not final API):**

```go
// kube_read.go
func init() { Register(kubeRead{}) }

type kubeRead struct{}

func (kubeRead) Metadata() ScopeMetadata {
    return ScopeMetadata{
        ID: "kube-read", Plane: PlaneKube, Type: TypeRead,
        Description: "…",
        Authorization: AuthorizationConfig{
            Approval:                "manual",
            AutoApproveEnvironments: []string{"ephemeral"},
            RequesterCannotApprove:  true,
            MinApprovers:            1,
            DefaultGrantHours:       4,
            DefaultPendingHours:     24,
        },
        RBAC: &actions.RBACConfig{ /* rules */ },
    }
}
```

```go
// aws_read.go
func init() { Register(awsRead{}) }

func (awsRead) Metadata() ScopeMetadata {
    return ScopeMetadata{
        ID: "aws-read", Plane: PlaneAWS, Type: TypeRead,
        AwsRoleKey: AwsRoleBreakglassRead,
        Authorization: AuthorizationConfig{
            Approval: "manual", /* stage+; no auto_approve envs in prod */
            RequesterCannotApprove: true, MinApprovers: 1,
            DefaultGrantHours: 4, DefaultPendingHours: 12,
        },
    }
}
```

- **Kube scopes:** `RBAC` lives **only** in the scope Go file (templates applied on first `connect` / `use`). No duplicate YAML in Terraform.
- **AWS scopes:** the Go file declares **`AwsRoleKey`** (enum / string constant). **IAM documents stay in Terraform** (sibling roles to `zoa_aws_read` / `zoa_aws_write`, BG-only trust to API Lambda). **No ARN hardcoded in Go.**

**Role ARN resolution (mirror TA, extended for more than two roles):**

| Layer                                                                                              | Responsibility                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Terraform** (`rosa-seaplane` `terraform/modules/zoa-lambda` or dedicated `breakglass` submodule) | Create `zoa_bg_aws_read`, `zoa_bg_aws_write`, `zoa_bg_aws_elevated` (names illustrative). Pass ARNs into API Lambda env.                                                                                                                                                                                                                                                                                                    |
| **Lambda env**                                                                                     | Either **discrete vars** `BREAKGLASS_AWS_READ_ROLE_ARN`, `BREAKGLASS_AWS_WRITE_ROLE_ARN`, `BREAKGLASS_AWS_ELEVATED_ROLE_ARN` (parallel to `AWS_READ_ROLE_ARN` / `AWS_WRITE_ROLE_ARN`), **or** one JSON map `BREAKGLASS_AWS_ROLE_ARNS='{"aws-read":"arn:…",…}'` rendered from `config/` → `deploy/` like other ZOA env. Prefer **map** if scope count grows; **discrete vars** match TA ergonomics for v1 (read/write only). |
| **`pkg/config`**                                                                                   | Parse env into `BreakglassAWSRoleARNs map[AwsRoleKey]string` on `Load()`.                                                                                                                                                                                                                                                                                                                                                   |
| **`pkg/scopes/aws_rolekey.go`**                                                                    | `func RoleARN(key AwsRoleKey, cfg *config.Config) (string, error)` — lookup env map; fail closed if missing.                                                                                                                                                                                                                                                                                                                |
| **`connect` / credential helper**                                                                  | `scopes.Get(request.Scope)` → kube: apply `Definition().RBAC`; aws: `sts.AssumeRole(RoleARN(cfg), …)` — same executor-level decision as TA, but keyed by **scope id** instead of `meta.Type` on each action.                                                                                                                                                                                                                |

**Validation at request time:** API rejects unknown `scope` strings via registry `Get` (404), same as unknown TA name on `zoa run`. **CLI** `zoa breakglass request --scope` can tab-complete from `scopes.List()`.

**Why not put AWS policies in the Lambda without Go?** Terraform must own IAM (review, FedRAMP evidence). Go must own **which scope uses which role** and kube RBAC rules so they are versioned with `revision` on the request and unit-tested — not scattered in Lambda handler switches.

#### Scope ids — align with TA **`read` / `write`**

TA metadata already uses **`Type`: `read` \| `write`** (`pkg/actions`). Break-glass scope names should be **`{plane}-read` / `{plane}-write`** so operators and approvers reuse the same mental model (“I need read-only” vs “I need to change something”). Optional **`{plane}-elevated`** later = “almost admin” with extra denies; **never** `*-admin` as a scope id.

| Scope               | Plane | Ship                 | Maps to TA `Type` | Access (summary)                                                     | Approval workflow (`approval`)                                                    |
| ------------------- | ----- | -------------------- | ----------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **`kube-read`**     | K8s   | **v1**               | `read`            | `get/list/watch`; **no** `secrets`; no HCP `cluster-*`; no RBAC bind | **`auto`** in ephemeral; **`manual`** elsewhere                                   |
| **`kube-write`**    | K8s   | v1                   | `write`           | patch/update on workloads; **no** Secrets; no cluster RBAC           | **`manual`** (1 approver, requester ≠ approver)                                   |
| **`kube-elevated`** | K8s   | **yes, after write** | —                 | **Near-admin** (§5.8.2)                                              | **`strict`** (note required; 2 approvers when supported; 1h grant; page optional) |
| **`aws-read`**      | AWS   | v1                   | `read`            | Describe/List/Get + **Deny** secrets/SSM/customer S3                 | **`manual`** (stage+); dev may override in config only                            |
| **`aws-write`**     | AWS   | after read           | `write`           | Near-admin, constrained (§5.8.2)                                     | **`manual`**; optional `require_decision_note` via config tighten                 |
| **`aws-elevated`**  | AWS   | **yes, after write** | —                 | Near-admin AWS (§5.8.2)                                              | **`strict`**; never auto                                                          |

**v1 slice:** **`kube-read`** + **`aws-read`** (CLI + console); **`kube-write`** for ephemeral/e2e. **`aws-write`** then **`kube-elevated` / `aws-elevated`** once policies and approval workflow exist.

#### Elevated (last-resort incidents) — near-admin, no `*-admin` id

Break-glass will be **infrequent** but must **unblock** incidents when TAs do not exist yet or cannot reach the failure mode. **`read`/`write` cover the 80%**; **`elevated` is the deliberate 5%** for “we are stuck.”

| Principle     | Choice                                                                                                                                                                                                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ship it?      | **Yes** — as **`kube-elevated` / `aws-elevated`**, not a scope literally named `admin` (avoids mental model = unlimited).                                                                                                                                                                         |
| vs true admin | **Elevated = near-admin** (wide operational Allow). **`write` = near-admin with a complex policy** (many Allow lines **and** many Deny lines). Still **never** attach AWS `AdministratorAccess` or bind K8s `cluster-admin` by name — custom roles that **behave** like admin minus exfiltration. |
| Approval      | Encoded per scope in **`Authorization`** (§5.7.1); **write** = `manual`; **elevated** = `strict`; tighten via config without new handlers.                                                                                                                                                        |
| TTL           | **`grantExpiresAt` shorter for elevated** (e.g. 1h default vs 4h for read/write) — config per scope id.                                                                                                                                                                                           |
| After action  | Operator policy: **follow with TA** to automate what they did; elevated usage triggers **post-incident review** metric/audit queue (process, not code in v1).                                                                                                                                     |
| Product story | ZOA remains daily driver (**session + `zoa run`**); BG elevated is **documented last resort** in runbooks, not listed beside `kube-read` in onboarding.                                                                                                                                           |

If elevated is requested **often**, that is a signal to **add or extend TAs**, not to widen elevated.

**UX note (Google-style SRE bar):** minimize choice — four core scopes, clear defaults, **read first** in docs; break-glass is the exception path when TA cannot help; prefer **`zoa run`** for repeatable work. Naming parity with TA reduces “which word do I use?” friction.

**Industry reference (not copy-paste):** AWS **read** ≈ ViewOnlyAccess minus secrets; **write** ≈ PowerUser with a **fat Deny** sidecar; **elevated** ≈ admin-minus-IAM/secrets. K8s: **read** ≈ aggregated `view`; **write** ≈ curated `edit` rulesets; **elevated** ≈ custom “admin-lite” ClusterRole (no `secrets`, no escalate).

#### 5.8.2 Permission design — read vs write vs elevated

K8s RBAC has **no Deny** — “deny” is **omit verbs/resources** or **ValidationWebhook** (out of scope v1). AWS IAM uses **explicit Deny wins** — **`write` leans on Deny complexity**, **`elevated` leans on broad Allow + minimal Deny**.

| Tier           | Operator intent                  | Kube (ClusterRole shape)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | AWS (IAM shape)                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`read`**     | Observe only                     | `get`, `list`, `watch` on core + OpenShift API groups; **no** `secrets` resource; **no** subresource `exec`/`proxy`/`attach`/`portforward`; optional exclude `hostedclusters` / `hostedcontrolplanes` in `cluster-*` if not needed for RC                                                                                                                                                                                                                                                                                                   | Allow `Describe*`, `List*`, `Get*` on platform services (from TA read baseline); **Deny** `secretsmanager:*`, `ssm:GetParameter*` on `SecureString`, customer S3 ARNs, `kms:Decrypt` except ZOA-owned keys                                                                                                                                                                                                                                                                                  |
| **`write`**    | Fix one thing surgically         | **Narrow Allow:** e.g. `deployments`, `statefulsets`, `daemonsets`, `replicasets`, `pods`, `events`, `configmaps` (not secrets), `machineconfigs` (OCP), selected `operators.*` — verbs `patch`, `update`, `delete` on **pods** only, `create` denied. **No** `clusterrole`, `clusterrolebinding`, `rolebinding` **create/patch**. Namespace-scoped ops default; cluster-scoped only where TA `rollout_restart` already needs it. Reuse namespace block list from `get_secret` (`cluster-*` prefixes) for **any** secret-adjacent resources | **Allow:** mutation allow-list per service (e.g. `eks:UpdateClusterConfig` off, `ec2:RebootInstances`, `elbv2:Modify*`, `autoscaling:SetDesiredCapacity`, …) — **curated**, not `*:*`. **Deny (long):** all `iam:*`, `organizations:*`, `account:*`, `sts:AssumeRole` except self-session, `secretsmanager:*`, broad `s3:*` except platform audit paths, `kms:Decrypt` on customer CMKs, `rds:Delete*`, `dynamodb:Delete*` on non-ZOA tables, etc. **This is the hard policy to maintain.** |
| **`elevated`** | Incident — unblock like an admin | **Wide explicit Allow** per apiGroup (not `resources: *` on `""` — that includes secrets): extend read groups with full verbs; `pods/exec`; no RBAC bind resources                                                                                                                                                                                                                                                                                                                                                                          | **Broad Allow:** `Action: *` on `Resource: *` in account + **short Deny** sidebar (IAM, org, secrets, customer data) — see §5.8.3                                                                                                                                                                                                                                                                                                                                                           |

**Implementation split (repeat for reviewers):**

| Tier     | `pkg/scopes/kube_*.go`                   | Terraform `breakglass_iam.tf`                                          |
| -------- | ---------------------------------------- | ---------------------------------------------------------------------- |
| read     | Full RBAC rules in Go                    | `zoa_bg_aws_read` policy document                                      |
| write    | Full RBAC rules in Go                    | `zoa_bg_aws_write` — **many statements** (Allow shards + Deny block)   |
| elevated | Full RBAC rules in Go (wide rules array) | `zoa_bg_aws_elevated` — **few statements** (star Allow + Deny sidebar) |

Each scope file’s **`ScopeMetadata`** carries human **`capabilities` / `restrictions`** bullets for `describe` (approvers see tier intent without reading IAM).

#### 5.8.3 Concrete RBAC (RC vs MC) and IAM policies (v1 draft for security review)

**Source of truth:** RBAC lives in **`pkg/scopes`** (`kube_read_rc.go`, `kube_read_mc.go`, …) as `[]actions.RBACRule`, applied to **`zoa-bg-<requestId>`** ClusterRole (+ Binding). The **same** `KubeReadRules(targetType)` should be imported by TA **`get_resource`** (replacing `apiGroups: *`, `resources: *`). Only **`get_secret`** keeps `AllowSecretRead` + explicit `secrets` rules.

**Target selection:** `ZOA_TARGET_TYPE` / `TargetTypes` on the scope registry — same as TAs (`list_db_gvks` RC-only, `must_gather` both).

**GitOps posture:** Most objects are ArgoCD-managed. **read** is safe for investigation; **write** is for **unstick** (pod delete, rollout annotation, scale) — changes may be reconciled away; persistent fixes belong in Git/Tekton.

**Namespace posture (illustrative — tune per env):**

| Target | Platform namespaces (read/write allow)                                                                                                                              | Blocked / elevated-only                                                                                                                                                                       |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **RC** | `argocd`, `platform-api`, `seaplane-*`, `zoa-jobs`, `cert-manager`, `ingress-*`, `monitoring`, `thanos`, `tekton-*`, `kube-system` (read), `openshift-*` if present | Customer/HCP N/A on RC                                                                                                                                                                        |
| **MC** | `hypershift`, `hypershift-*`, `zoa-jobs`, `monitoring`, `cert-manager`, `openshift-*`, `kube-applier`, `vector`                                                     | **`cluster-*`** (HCP): **no read of secrets**; **write** discouraged; **elevated** may allow limited `get/list/patch` on HostedCluster/NodePool **without** secret access — security sign-off |

---

##### Kubernetes — RC (`kube-read` / shared `get_resource`)

**Verbs (all rules):** `get`, `list`, `watch` only.

**Rule set A — core (`apiGroups: [""]`) — explicit resources (no `secrets`, no `serviceaccounts/token`):**

`configmaps`, `endpoints`, `events`, `namespaces`, `nodes`, `persistentvolumeclaims`, `persistentvolumes`, `pods`, `pods/log`, `podtemplates`, `replicationcontrollers`, `resourcequotas`, `services`, `limitranges`

**Rule set B — standard workloads:**

| apiGroups           | resources                                                                         |
| ------------------- | --------------------------------------------------------------------------------- |
| `apps`              | `deployments`, `replicasets`, `statefulsets`, `daemonsets`, `controllerrevisions` |
| `batch`             | `jobs`, `cronjobs`                                                                |
| `autoscaling`       | `horizontalpodautoscalers`                                                        |
| `policy`            | `poddisruptionbudgets`                                                            |
| `networking.k8s.io` | `networkpolicies`, `ingresses`                                                    |
| `discovery.k8s.io`  | `endpointslices`                                                                  |

**Rule set C — platform / GitOps (resources `*` within group — **not** global `*`):**

| apiGroup                                                   | RC notes                                                                                                                   |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `seaplane.io`                                              | Regional operator CRDs (`clusters`, `managementclusters`, …)                                                               |
| `argoproj.io`                                              | `applications`, `appprojects` (read-only; Argo meta)                                                                       |
| `tekton.dev`, `triggers.tekton.dev`, `operator.tekton.dev` | Pipelines (read)                                                                                                           |
| `monitoring.coreos.com`                                    | PrometheusRules, ServiceMonitors, etc. (read)                                                                              |
| `apiextensions.k8s.io`                                     | `customresourcedefinitions` (discover GVRs)                                                                                |
| `rbac.authorization.k8s.io`                                | `roles`, `clusterroles`, `rolebindings`, `clusterrolebindings` — **get/list only** (debug who can do what; not escalation) |

**Explicit omissions:** `secrets`, subresources `pods/exec`, `pods/portforward`, `pods/attach`, `services/proxy`, any verb `create|update|patch|delete`.

---

##### Kubernetes — MC (`kube-read` / shared `get_resource` on MC)

Same as **RC rule sets A + B**, plus MC **rule set C′**:

| apiGroup                                                      | MC notes                                                                     |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `hypershift.openshift.io`                                     | `hostedclusters`, `hostedcontrolplanes`, `nodepools`, … — **get/list/watch** |
| `seaplane.io`                                                 | Only if MC registers any (usually minimal)                                   |
| `cluster.x-k8s.io`, `infrastructure.cluster.x-k8s.io`         | If CAPI present — read                                                       |
| Same Argo/Tekton/monitoring groups as RC where deployed on MC |                                                                              |

**HCP namespaces `cluster-*`:** optional **narrow** rule — `get/list/watch` on `pods`, `events`, `services`, `configmaps` **only** (no CRDs with credentials in MC read v1). Full HostedCluster API read uses `hypershift.openshift.io` cluster-scoped rules above, not Secrets inside `cluster-*`.

---

##### Kubernetes — RC `kube-write`

**Verbs:** `get`, `list`, `patch`, `update` on workloads; **`delete`** only on **`pods`** and **`jobs`** (stuck terminating).

| apiGroups | resources                                                  | verbs                                             |
| --------- | ---------------------------------------------------------- | ------------------------------------------------- |
| `apps`    | `deployments`, `daemonsets`, `statefulsets`, `replicasets` | get, list, patch, update                          |
| `batch`   | `jobs`                                                     | get, list, patch, update, **delete**              |
| `""`      | `pods`                                                     | get, list, patch, update, **delete**              |
| `""`      | `configmaps`                                               | get, list, patch, update — **no** delete (GitOps) |

**ClusterRoleBinding:** prefer **RoleBinding** limited to platform namespace list (RC table) unless a TA already needs cluster-scoped patch (mirror `rollout_restart`).

**Forbidden (all write tiers):** `secrets`, `serviceaccounts`, RBAC `create|patch|delete`, `argoproj.io` **Application** delete, `hostedclusters` delete.

---

##### Kubernetes — MC `kube-write`

Same as RC **kube-write**, namespaces = MC platform list **excluding** `cluster-*` by default. Optional: **delete pod** in `hypershift` / `openshift-*` only.

---

##### Kubernetes — RC / MC `kube-elevated`

**ClusterRole (single binding, cluster-wide):** K8s has **no Deny** — **`resources: ["*"]` would include `secrets`**, so elevated **must not** use global star rules. Use **read rule sets A+B+C (or C′)** plus **wide mutate rules** on the same apiGroups with explicit resource lists (or `*` **within** each group **except** `secrets` in core).

**Elevated add-ons (examples):**

1. Core `""`: add `pods/exec` → `create`; `pods/portforward`, `pods/attach` if needed; `delete` on all rule-set A resources except `namespaces`.
2. `apps`, `batch`, `networking.k8s.io`, `policy`, platform groups: verbs `create`, `update`, `patch`, `delete` on resources already listed in read (not expanding into `secrets`).
3. `hypershift.openshift.io` (MC): `patch`, `update`, `delete` on selected kinds (e.g. `nodepools`) — **not** blanket delete `hostedclusters` in v1.
4. `nonResourceURLs`: `/healthz`, `/readyz`, `/api`, `/apis` — `get`.

**Still no rules granting:** `secrets`, `serviceaccounts` (or token create), any mutate on `clusterroles`, `clusterrolebindings`, `roles`, `rolebindings`.

**MC addition:** may **patch/update/delete** broader resource kinds in `hypershift.openshift.io` (e.g. unstick NodePool) — still **no** `secrets`; avoid delete `hostedclusters` in v1 unless runbook exception.

---

##### AWS IAM — `zoa_bg_aws_read` (BG role, API Lambda trust only)

**Baseline:** TA `zoa_aws_read` Describe/List (EC2, EKS, ELB, Route53) **without** TA artifact `s3:PutObject` / Job upload paths.

**Add read for investigation:**

`logs:Describe*`, `logs:FilterLogEvents`, `logs:GetLogEvents`, `cloudwatch:GetMetric*`, `cloudwatch:List*`, `lambda:Get*`, `lambda:List*`, `ecs:Describe*`, `ecs:List*`, `dynamodb:Describe*`, `dynamodb:List*`, `rds:Describe*`, `elasticache:Describe*`, `apigateway:GET`, `kms:Describe*`, `kms:List*`, `ssm:Describe*`, `ssm:List*` (no `GetParameter` in **read** v1), `events:Describe*`, `events:List*`, `sns:Get*`, `sns:List*`, `sqs:Get*`, `sqs:List*`, `sts:GetCallerIdentity`

**Explicit Deny (attach as second policy or statement):**

`secretsmanager:Get*`, `secretsmanager:List*`, `ssm:GetParameter`, `ssm:GetParameters`, `kms:Decrypt`, `kms:GenerateDataKey*`, `iam:*`, `organizations:*`, `account:*`, `s3:GetObject`, `s3:List*` on customer/data prefixes (allow-list **only** platform audit bucket if needed), `sts:AssumeRole` (except role session itself)

---

##### AWS IAM — `zoa_bg_aws_write` (constrained; long Deny)

**Allow shards (examples — region account, platform only):**

| Service         | Actions                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------ |
| EC2             | `RebootInstances`, `StartInstances`, `StopInstances`, `ModifyInstanceAttribute` (exclude `userData` via Deny)      |
| EKS             | `Describe*`, `List*` only — **no** cluster create/delete                                                           |
| ELB             | `ModifyListener`, `ModifyRule`, `RegisterTargets`, `DeregisterTargets`, `SetRulePriorities`                        |
| Auto Scaling    | `SetDesiredCapacity`, `UpdateAutoScalingGroup` (tag-conditioned where possible)                                    |
| ECS             | `StopTask`, `UpdateService`, `UpdateServicePrimaryTaskSet` — ZOA boundary tasks are ZOA-owned; no `RunTask` create |
| Lambda          | **no** `UpdateFunctionCode` in v1 — read + invoke diagnostic only if needed                                        |
| CloudWatch Logs | `CreateLogStream`, `PutLogEvents` only on `/aws/lambda/<prefix>-zoa-*` log groups (tight ARN pattern)              |

**Deny block (always on):** all from **read** Deny, plus `ec2:TerminateInstances`, `ec2:Delete*`, `rds:Delete*`, `rds:ModifyDBInstance` (destructive), `dynamodb:DeleteTable`, `dynamodb:UpdateTable`, `s3:Delete*`, `lambda:Delete*`, `ecs:Delete*`, `eks:DeleteCluster`, `eks:UpdateClusterConfig`, `sts:AssumeRole`, broad `*:*` except where Allow shards apply (use **policy structure: default Deny + explicit Allow**, not `*` Allow)

---

##### AWS IAM — `zoa_bg_aws_elevated` (near-admin, short Deny)

**Allow:** `Action: "*", Resource: "*"` on **single regional account** (this deployment account only).

**Deny (short sidebar — overrides Allow):**

`iam:*`, `organizations:*`, `account:CloseAccount`, `account:Delete*`, `secretsmanager:*`, `ssm:GetParameter*`, `kms:Decrypt`, `kms:ImportKeyMaterial`, `s3:GetObject`, `s3:PutObject` on `arn:aws:s3:::*customer*` patterns (use env-specific prefix list), `sts:AssumeRole` to other roles, `ec2:ModifyInstanceAttribute` on `userData`, `rds:Delete*`, `dynamodb:Delete*`

Session: `RoleSessionName` `bg-<requestId>`, tags `ZOAScope=aws-elevated`, mandatory `SourceIdentity` when bridge hits.

---

##### Maintenance

| Artifact              | Update trigger                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| RC/MC apiGroup lists  | New Argo app / operator CRD in `argocd/config` → extend rule set C / C′ or regenerate from `oc api-resources` in CI |
| Namespace allow-lists | Tekton/Argo path changes in `rosa-seaplane` config                                                                  |
| IAM Allow shards      | New regional pipeline–owned service that SRE must poke in incident                                                  |
| `get_resource`        | Must stay aligned with **`kube-read`** — one function `scopes.KubeReadRBAC(targetType)`                             |

**Security review gate:** sign off **§5.8.3** before enabling `kube-write` / `aws-write` in stage; **elevated** requires second approver + this appendix attached to MR.

#### AWS access modes (CLI + console from day one for `aws-*` scopes)

Boundary has **no Red Hat SAML / Kerberos** like the laptop; do **not** run [rh-aws-saml-login](https://github.com/app-sre/rh-aws-saml-login) for BG. That tool’s **`--console`** flag is the **UX reference**: after credentials exist, open (or print) a **service-scoped console URL**. ZOA does the same **after API `AssumeRole`** for the grant using AWS **federation / sign-in token** from the **same STS session** as CLI — one grant, two surfaces.

| Mode        | v1                   | Notes                                                                                                                                                                                                                                                                                                                                                                               |
| ----------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CLI**     | **Yes**              | Hidden `credential_process` + AssumeRole (`DurationSeconds` capped by grant).                                                                                                                                                                                                                                                                                                       |
| **Console** | **Yes** (aws scopes) | `zoa breakglass use <id> --console` and/or `--console-service <svc>` (mirror rh-aws-saml-login). API mints federation URL; output **only the URL** (or copy-to-clipboard if available) — **never** access key material. Audit `breakglass_console_link`. Optional: deny console on `aws-write` until security review. Default remains CLI-only flags (no console unless requested). |

**Policy work:** implement Terraform from **§5.8.3**; iterate in `breakglass_iam.tf` + `pkg/scopes/kube_*_{rc,mc}.go`.

---

## 6. HTTP API (`HANDLER_MODE=api` unless noted)

Prefix: **`/api/v0`** — constants in **`pkg/api/paths.go`** (same file as `PathTrustedActions`, `PathSessions`).

**Parallel to Trusted Actions:**

| TA today                                    | Break-glass                                                  |
| ------------------------------------------- | ------------------------------------------------------------ |
| `PathTrustedActions` → catalog              | `PathBreakglassScopes` → scope catalog                       |
| `GET …/trusted-actions/{action}` → describe | `GET …/breakglass/scopes/{scope}` → describe                 |
| `PathTrustedActionsRuns` → runs             | `PathBreakglassRequests` → grant requests                    |
| `POST …/trusted-actions/{action}/run`       | `POST …/breakglass/requests` (create)                        |
| `GET …/trusted-actions/runs/{id}`           | `GET …/breakglass/requests/{id}`                             |
| —                                           | `POST …/breakglass/requests/{id}/connect` (task-bound creds) |

**Proposed `paths.go` additions:**

```go
const (
    PathBreakglass         = V0Prefix + "/breakglass"
    PathBreakglassScopes   = PathBreakglass + "/scopes"
    PathBreakglassRequests = PathBreakglass + "/requests"
)
```

| Method | Path constant usage                        | Caller              | Description                                                                                |
| ------ | ------------------------------------------ | ------------------- | ------------------------------------------------------------------------------------------ |
| `GET`  | `PathBreakglassScopes`                     | Boundary            | List scopes (`items[]` = `ScopeMetadata`, same envelope as list actions).                  |
| `GET`  | `PathBreakglassScopes + "/{scope}"`        | Boundary            | Describe scope (404 unknown/disabled).                                                     |
| `POST` | `PathBreakglassRequests`                   | Boundary            | Create request; body: `scope`, `reason`, optional `target`.                                |
| `GET`  | `PathBreakglassRequests + "/{id}"`         | Boundary / approver | Status, no secrets.                                                                        |
| `GET`  | `PathBreakglassRequests`                   | Boundary            | List **mine** (`?scope=mine` query — **not** BG scope id; means “my rows”, like sessions). |
| `POST` | `PathBreakglassRequests + "/{id}/connect"` | Boundary            | Task-bound connect / lazy provision.                                                       |
| `POST` | `PathApprove + "{id}"`                     | Access / API        | Execution UUID **or** break-glass UUID.                                                    |
| `POST` | `PathReject + "{id}"`                      | Access / API        | Same.                                                                                      |

Access Lambda (optional v1): `GET PathBreakglassRequests?scope=all` for approvers — phase 2.

**Error envelope:** same as TA/access today.

**Audit types:** `breakglass_request`, `breakglass_approve`, `breakglass_connect`, `breakglass_credential` (plugin refresh), `breakglass_expire` in existing `audit` DynamoDB table; `zoa audit --type breakglass`.

---

## 7. CLI (inside boundary)

Command group: **`breakglass`** (new `cmdGroupBoundary` or sibling to `session` on laptop). Shown in `zoa --help` only when `ZOA_API_URL` is set (like `run`).

| Command                                       | Description                                                                                                                                                                                                  |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `zoa breakglass scopes` [`<scope>`]           | List scopes (catalog); optional arg = short describe. See §7.2.                                                                                                                                              |
| `zoa breakglass describe <scope>`             | Full scope detail (approval, TTL, can/cannot).                                                                                                                                                               |
| `zoa breakglass request <scope> --reason REQ` | Create BG request (`kube-read`, `aws-read`, …). Uses default target from `ZOA_TARGET` / deployment.                                                                                                          |
| `zoa breakglass requests`                     | List my grant requests (pending + approved). **Alias:** `list` for ergonomics. Mirrors **`zoa runs`** ↔ `PathTrustedActionsRuns`.                                                                            |
| `zoa breakglass status <request-id>`          | Poll approval / expiry (`request-id` = UUID from create/list).                                                                                                                                               |
| `zoa breakglass use <request-id>`             | After approved: provision + activate kube/aws for this shell (**silent** config). Idempotent while grant valid. **`--console`** / **`--console-service`** for AWS (v1). API: `POST …/connect` until renamed. |

**Laptop (approver):**

| Command                                               | Description                                                                        |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `zoa approve <deployment>/<request-id> [--comment …]` | Top-level; compound id routes Access to the target API (same pattern as sessions). |
| `zoa reject <deployment>/<request-id> --reason …`     | Same.                                                                              |

No `zoa breakglass request` on laptop (enforced by missing `ZOA_API_URL` + docs).

**Reason:** reuse `--reason` / `ZOA_REASON` convention from boundary banner.

### 7.1 Shell: silent activate + prompt (kube + aws in parallel)

Boundary already uses a **two-line PS1** (`sessionId:…` + `operator@zoa:deployment/target` in `boundary/home-sre/.bashrc.d/10-zoa-prompt.bashrc`). Break-glass adds **state in the prompt**, like kubectl context / `kube-ps1`, without calling `kubectl` every redraw.

**`~/.config/zoa/breakglass/active`** (written by `use`, no secrets — safe if ever logged):

```json
{
  "kube": {
    "requestId": "<uuid>",
    "scope": "kube-read",
    "grantExpiresAt": "2026-04-08T18:00:00Z"
  },
  "aws": {
    "requestId": "<uuid>",
    "scope": "aws-read",
    "grantExpiresAt": "2026-04-08T20:00:00Z"
  }
}
```

- **`use` sets only the stanza(s) implied by that request’s `scope`** (kube scopes → `kube`, aws scopes → `aws`). Two approved grants → two `use` calls → **both** stanzas populated — kube and aws BG **at once** with different `requestId`s.
- **`11-zoa-breakglass-prompt.bashrc`:** on each prompt, read `active`; if `grantExpiresAt` passed, clear that stanza + env (no API call); set `KUBECONFIG` / `AWS_PROFILE` from filesystem paths derived from `requestId` (**no export echoed**).
- **Third prompt line** (or compact suffix on line 2), e.g. `breakglass: kube=kube-read (~1h) aws=aws-read (~2h)` — scope + **time remaining**, not profile paths or UUIDs (optional truncated id only if support asks; default **scope only**).
- Optional later: enable **`kube-ps1`** on line 3 when `kube` stanza active (cluster/context from env) — same mental model as ROSA boundary; not required for v1 if scope line is enough.

**`use` stdout:** may be **empty on success** when prompt is updated — operator confirmation is the new break-glass segment on PS1, not a printed banner.

### 7.2 Scope catalog UX (mirror `zoa actions` / `zoa describe`)

Operators need to pick **`kube-read` vs `kube-write`** (etc.) **before** `request`, with the same discoverability as Trusted Actions. The **one Go file per scope** is not only for RBAC/IAM wiring — it is the **source of truth for catalog metadata** (description, approval, TTL, plane, examples), exactly like each TA file’s `Metadata()`.

**Naming (avoid “profile” in product copy):**

| Term                     | Use                                                                                                                                                                              |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **scope** / **scope id** | User-facing: `kube-read`, `aws-write`. This is what you **request**.                                                                                                             |
| **plane**                | `kube` \| `aws` — derived from scope id prefix; shown in list tables, not a separate CLI argument in v1.                                                                         |
| **type**                 | `read` \| `write` \| `elevated` — aligns with TA `Type`; shown in list/describe for muscle memory.                                                                               |
| **profile**              | **Do not** use in help for scopes — reserved for **`AWS_PROFILE=zoa-bg-<requestId>`** (artifact after `use`). Say “scope” or “access level” in runbooks if plain language helps. |
| ~~scope-type~~           | Avoid — sounds like two concepts; the id already encodes `{plane}-{type}`.                                                                                                       |

**CLI (boundary only, `ZOA_API_URL` set):** same patterns as `internal/cli/actions.go` — online API authoritative, **`--offline`** embedded registry from this CLI build for docs/Claude in boundary.

| Command                                       | TA analogue               | Purpose                                                                                                                                                 |
| --------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `zoa breakglass scopes`                       | `zoa actions`             | Table: `SCOPE`, `PLANE`, `TYPE`, `TTL`, `APPROVAL`, `DESCRIPTION`.                                                                                      |
| `zoa breakglass scopes <scope>`               | `zoa actions <action>`    | Short describe on stdout (same as `describe` subcommand).                                                                                               |
| `zoa breakglass describe <scope>`             | `zoa describe <action>`   | Full detail: what you can/cannot do (human bullets), default grant hours, approval rule, example `request` line, optional `--console` note for `aws-*`. |
| `zoa breakglass scopes --offline`             | `zoa actions --offline`   | No API; filter by `--target-type rc\|mc` if a scope is plane-specific later (v1: same six scopes on both).                                              |
| `zoa breakglass scopes --offline -o markdown` | `zoa actions -o markdown` | Boundary cheat sheet for agents / operator guide.                                                                                                       |

**Shell completion:** `zoa breakglass request` completes scope ids from registry (offline: `scopecatalog.List()`; online: optional cache from last `scopes` call or lightweight `GET`).

**HTTP API (read-only, no auth secrets):**

| Method | Path                             | Notes                                                                                                                               |
| ------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/api/v0/breakglass/scopes`      | `{ "items": [ ScopeDescribe, … ] }` — filter env: hide scopes not shipped in this deployment (e.g. no `kube-elevated` in prod yet). |
| `GET`  | `/api/v0/breakglass/scopes/{id}` | 404 if unknown or disabled. Body = `ScopeDescribe` JSON (not raw IAM policy or full RBAC rule YAML in v1).                          |

**`ScopeDescribe` fields (operator-safe, for list/describe):**

- `id`, `plane`, `type`, `description`, `examples[]` (e.g. `zoa breakglass request kube-read --reason …`)
- `authorization` object (same JSON as `AuthorizationConfig` — `approval`, `min_approvers`, `require_decision_note`, TTL defaults) so describe matches enforce
- `capabilities[]` / `restrictions[]` — short bullets (“get/list pods; no secrets”; “AWS Describe\*; deny Secrets Manager”)
- `console_supported` (bool, aws scopes)
- `enabled` (bool) — deployment may turn off a scope without removing code
- **Do not** expose: role ARNs, `AwsRoleKey`, full `RBACConfig` rules in public JSON (security noise + drift); optional `GET …/scopes/{id}?include=policy` for **admin** later.

**Implementation mirror:**

- `pkg/scopes/*.go` — `Metadata() ScopeMetadata` (catalog/describe) + `RBAC()` / `AwsRoleKey()` for provision.
- `internal/cli/scopecatalog/` — embed/list for `--offline` (copy `actioncatalog` pattern).
- API — `handleListBreakglassScopes` / `handleDescribeBreakglassScope` in **`pkg/api/breakglass.go`**, wired like `handleListActions` / `handleDescribeAction`.

**Operator journey (UX):**

1. Incident → still try **`zoa actions`** / **`zoa run`** first (docs say this).
2. Not enough → **`zoa breakglass scopes`** → **`zoa breakglass describe kube-read`** (or write) to confirm fit.
3. **`zoa breakglass request <scope> --reason …`** → wait / approver.
4. **`zoa breakglass use <request-id>`** — prompt shows active **scope**, not “profile”.

**Approve UX (laptop):** approver sees **`scope`** + `reason` on approve notification; optional future `zoa breakglass describe <scope> --offline` on laptop if Access proxies read-only scope catalog (phase 2 — not required if compound approve UI shows capabilities summary from API).

---

## 8. Worker / GC (reuse TA patterns)

Today’s GC (`pkg/scheduler/gc.go`) is **DynamoDB-first**, not “dumb label-only”:

1. **`garbageCollect`** — query **terminal executions** (succeeded/failed/timed_out) after a short delay → `CleanupExecution(ctx, executionId, …)` which deletes **`zoa-exec-<executionId>`** resources → `MarkCleaned` on the row.
2. **`orphanGC`** — list **Jobs** with `app.kubernetes.io/managed-by=zoa` + `zoa.openshift.io/execution-id`; if **no execution row** and job is old → `CleanupExecution` anyway (crash / TTL / missed write).

Break-glass should **plug into the same Worker**, not a parallel design:

| Phase                 | Where                                                  | Behavior                                                                                                                                                                                                                                                                                                                                              |
| --------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Expiry**            | `pkg/scheduler/breakglass.go` (same 5m tick as reaper) | Query `target-status-index` for pending/grant deadlines → `status=expired` → call **`CleanupBreakglass(requestId)`** (mirror `CleanupExecution`: delete `zoa-bg-<requestId>` + bindings by derived name / shared label). Optional short **gcDelay** (e.g. 5m) after `grantExpiresAt` like TA terminal GC — tokens already dead, this is RBAC hygiene. |
| **Orphan safety net** | Extend **`RunGC`** (dedicated GC EventBridge schedule) | List cluster-scoped (and namespaced) objects with **`zoa.openshift.io/request-id`**; if **no row** or row already `expired`/`rejected`/`failed` → delete. Same “stupid but safe” philosophy as `orphanGC`, not a second source of truth.                                                                                                              |
| **AWS**               | —                                                      | **Nothing to delete** in AWS API; STS expires. Do not “revoke” sessions in v1 beyond TTL.                                                                                                                                                                                                                                                             |

### Kube: is access really temporary?

Yes, in two layers:

- **Tokens:** `TokenRequest` uses `expirationSeconds = min(remaining grant, 3600)` — no token outlives the grant window; plugin refresh stops once API denies expired grant.
- **RBAC:** SA/Role remain until Worker/**GC** deletes them after `grantExpiresAt` (+ optional delay). A copied token may still work **until its own expiry** (bearer caveat §5.5) even if RBAC is gone — deleting RBAC on schedule is **correct** and matches TA posture (remove episodic identity quickly).

Being “cautious” about AWS deletion is a non-issue (no resources). For kube, **delete RBAC when Dynamo says expired**; do not keep SA for the full 4h after last use unless grant is still valid.

No BG-specific Lambda binary.

---

## 9. Terraform (`rosa-hyperfleet`)

Per RC/MC (same module as `zoa-lambda`):

- **AWS:** one IAM role per scope (e.g. `…-zoa-breakglass-aws-read`, `…-zoa-breakglass-aws-write`) — parallel naming to TA `zoa_aws_read` / `zoa_aws_write`, **distinct ARNs**. Trust **API Lambda** only; **Deny** secrets paths.
- **Kube:** no Terraform roles; scope RBAC lives in **zoa** code, applied by API on `use`.
- Config YAML: `breakglass_scopes:` map `scope_id → { approval?, min_approvers?, require_decision_note?, auto_approve_environments?, grant_hours?, pending_hours? }` — **overrides tighten** workflow/TTL from `pkg/scopes` defaults; `breakglass_grant_duration_seconds` global fallback only when scope omits grant hours.
- **`breakglass_role_arns` on boundary task:** **empty** (credentials only via API).
- Optional: feature flag `enable_zoa_breakglass` default false until e2e ready (data plane tables can exist unconditionally like boundary-sessions).

---

## 10. Observability (EMF) — cost-conscious

ZOA runs in **RC + N MCs**; each distinct metric × label set is a **billable custom metric time series** (~$0.30/mo each at scale). Prefer **sessions-style efficiency** (HTTP + worker tick health + native AWS) over a large BG-specific catalog.

Reference: [`docs/observability.md`](https://github.com/openshift-online/rosa-seaplane-zoa/blob/main/docs/observability.md) — sessions do **not** emit per-session EMF counters; they use **`EmitAccessHTTPRequest`** / **`EmitReaper`** and platform metrics. TAs use **`ExecutionCount`** with **`Action`** as the main cardinality driver (remove or narrow `Action` later if series growth hurts).

### v1 break-glass (minimal new series)

| Signal                            | Mechanism                                                                                                       | New time series?                                                                                                                                               |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| API health (create, use, approve) | **`EmitHTTPRequest`** — add route templates for `/api/v0/breakglass/…` in `NormalizeRoute` (same as TA routes)  | **No** — reuses `HttpRequestCount` / `HttpRequestDuration` × `Cluster` × `RouteTemplate` × `StatusClass`                                                       |
| Worker expiry / cleanup failures  | Existing **`EmitReaper`** / **`EmitGC`** tick (`phaseErrors`++) when break-glass phase fails; logs carry detail | **No** — reuses `ReaperErrors` / `GCErrors` per cluster                                                                                                        |
| K8s delete after expiry           | **`EmitGCCleaned`** with `ResourceType=breakglass` (optional; same as `job` today)                              | **Low** — +1 ResourceType value × clusters                                                                                                                     |
| Approve vs reject mix             | **One** counter: **`BreakGlassDecision`**                                                                       | **Yes** — keep dimensions **only** `Cluster` + **`Outcome`** (`approved` \| `rejected`). **No `Scope`, no `Auto`, no `DenyReason` in v1** (~2 × (1+N) series). |

**Do not add in v1:** per-scope counters, use/deny reason breakdowns, provision duration histograms, active-grant gauges, or duplicate approved/rejected metric names.

Detail for debugging: **`audit`** + Dynamo + HTTP logs — not extra labels.

### Alerts / dashboards

- SLO-style: HTTP 5xx rate on break-glass route templates (per cluster).
- Optional: `sum by (Outcome) (BreakGlassDecision)` for approval policy drift.
- Reaper/GC error counters unchanged pattern from [`zoa.yaml`](https://github.com/openshift-online/rosa-seaplane/blob/main/argocd/config/regional-cluster/alerting-rules/templates/zoa.yaml).

### Future (only if needed)

- **`Scope` on `BreakGlassDecision`**: multiply series by ~3–5 scopes per cluster — justify in a PR with cardinality estimate.
- **TA manual approval**: reuse **`BreakGlassDecision`-shaped helper** (`Cluster` + `Outcome` only). Do **not** add `Action` to approval metrics; keep `Action` on terminal **`ExecutionCount`** only (today’s TA cost tradeoff).

---

## 11. Suggested implementation phases

1. **Storage + API skeleton:** request/grant types, pending/approved/expired, auto-approve, audit events, approve/reject wiring (no K8s yet).
2. **Kube connect:** SA + RBAC + TokenRequest + CLI local files; reconciler cleanup; e2e in ephemeral.
3. **Manual approval:** approver rules, requester≠approver, Access Lambda approve from laptop.
4. **AWS scopes:** Terraform roles + AssumeRole connect path.
5. **Hardening:** deny high scopes on identity bridge miss; alerts; docs in `docs/break-glass/`.

---

## 12. Open decisions (short)

| Topic                                | Proposal                                                                                                                                                                        |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pendingTTL` (`requestExpiresAt`)    | Max time **unapproved** request stays valid; e.g. 4–24h by env (prod manual approval may be shorter). **Not** the same as post-approve 4h grant.                                |
| Eager vs lazy provision              | Lazy on first `connect`; clock still `decisionAt + 4h`.                                                                                                                         |
| Namespace for BG SA                  | `zoa-system` or `kube-system` — match TA SA placement pattern.                                                                                                                  |
| Scope IAM/RBAC text                  | Security review on **§5.8.3** before stage write/elevated; align `get_resource` with RC/MC `kube-read`.                                                                         |
| Console on `aws-write`               | Allow from v1 or gate until policy sign-off.                                                                                                                                    |
| Elevated approval                    | `strict` metadata ships with `MinApprovers: 2` when dual-approve exists; v1 may use `MinApprovers: 1` + `RequireDecisionNote: true` as interim.                                 |
| Elevated TTL                         | Default 1h vs 4h for read/write.                                                                                                                                                |
| Approve from API only vs Access only | Both (already designed for TA).                                                                                                                                                 |
| Unified approve route                | **One** `/approve/{id}`: UUID in path/body is opaque; handler uses **deployment context** + lookup in `executions` vs `zoa-breakglass` tables (no TA/BG prefix in stored ids).  |
| Early terminate / revoke             | **Out of scope v1.** Access ends at `grantExpiresAt` (or pending `requestExpiresAt`). Operator closes boundary session if they need to stop sooner; Worker cleans up on expiry. |

---

## 13. Acceptance (MVP)

1. SRE in boundary: `zoa breakglass request kube-read --reason INC-1` → auto-approved in dev.
2. Within 4h of approve: `zoa breakglass use <request-id>` → `kubectl get ns` works with no manual config and no export spam in the transcript.
3. K8s audit shows SA `zoa-bg-…`; DynamoDB / `zoa audit` links grant → operator → boundary session.
4. Different task id cannot `connect` to same grant (403).
5. After `grantExpiresAt`, connect fails; reconciler removes SA/RBAC.
6. Approver can `zoa approve <deployment>/<request-id>` from laptop when manual mode enabled.
7. Observability: break-glass HTTP routes on existing `HttpRequestCount`; optional `BreakGlassDecision` (`Cluster` + `Outcome`); worker errors via existing Reaper/GC metrics.

---

_This proposal supersedes informal ChatGPT architecture notes. Implementation should follow `rosa-hyperfleet-zoa` conventions (`When … it should …` tests, `make all`, no secrets in logs)._
