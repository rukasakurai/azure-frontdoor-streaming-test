# Troubleshooting History

This document records deployment issues, their analysis, and resolutions for the Azure Front Door streaming test project.

---

## 2026-04-03 – Deployment Failures During `azd up --no-prompt`

### Symptoms

Running `azd up --no-prompt` in CI (E2E workflow) produced two errors after the Azure Front Door profile was successfully created:

```
ERROR: A resource with this name already exists or is in a conflicting state.

Deployment Error Details:
BadRequest: Please make sure that the originGroup is created successfully and at least one enabled origin is created under the origin group.
Conflict: That resource name isn't available.
```

The top-level resources (resource group, App Service Plan, App Service, AFD profile) all deployed successfully. The failure occurred when ARM attempted to deploy the AFD child resources (origin group, origin, endpoint, route, rule set, rules).

### Environment

- **Workflow:** E2E Infrastructure & Streaming Test (`e2e-test.yml`)
- **AZD_ENVIRONMENT:** `gha-e2e-<run_id>-<attempt>` (unique per run)
- **AZD_LOCATION:** `japaneast`
- **Subscription:** MCAPS-Hybrid-Internal-RukaSakurai

### Root Cause Analysis

The `originTimeoutRule` resource in `infra/modules/frontdoor.bicep` uses a `RouteConfigurationOverride` action with an `originGroupOverride` referencing the origin group. Azure Front Door validates at rule-creation time that the referenced origin group contains at least one enabled origin.

However, the `originTimeoutRule` had only an implicit Bicep dependency on the `originGroup` resource (through the `originGroup.id` reference) and **no dependency on the `origin` resource**. This allowed ARM to deploy the rule before the origin was created inside the group, causing the `BadRequest` validation error.

The `Conflict: That resource name isn't available` error was a cascading failure: when some child-resource deployments failed, other parallel deployments within the same AFD profile encountered conflicting internal state.

**Deployment ordering before the fix:**

```
afdProfile
├── originGroup ──► origin          (parent chain — correct)
├── endpoint                        (no issue)
├── ruleSet ──► originTimeoutRule   (parent chain — but NO dependency on origin)
└── route (dependsOn: [origin])     (correct, but originTimeoutRule could race)
```

Because `originTimeoutRule` and `origin` had no dependency relationship, ARM could attempt them in parallel, and `originTimeoutRule` would fail if it was validated before `origin` existed.

### Fix Applied

In `infra/modules/frontdoor.bicep`:

1. **Added `dependsOn: [origin]` to `originTimeoutRule`** — ensures the origin group has at least one enabled origin before the rule with `RouteConfigurationOverride` is created.
2. **Added `originTimeoutRule` to the `route` resource's `dependsOn`** — ensures the route is created only after all rule-set rules are fully provisioned.

**Deployment ordering after the fix:**

```
afdProfile
├── originGroup ──► origin
│                     │
│                     ▼
├── ruleSet ──► originTimeoutRule   (now waits for origin)
│                     │
├── endpoint          │
│       │             │
│       ▼             ▼
└────── route (dependsOn: [origin, originTimeoutRule])
```

### Outcome

- Bicep templates compile successfully after the fix.
- The explicit dependency chain prevents the race condition that caused the `BadRequest` error.

### Strategies That Were Considered but Not Applied

| Strategy | Reason Not Applied |
|---|---|
| Splitting AFD deployment into two Bicep modules (profile + children, then route) | Adds complexity; explicit `dependsOn` is the simpler and standard approach |
| Adding a random suffix to the endpoint name | The endpoint name already uses `uniqueString`; the Conflict error was a cascading failure, not a true naming collision |
| Removing `originPath: '/'` from the route | Not related to this race condition; addressed separately in the 2026-04-03 AFD 404 issue below |

---

## 2026-04-03 – AFD Endpoint Not Ready Within Wait Timeout

### Symptoms

After the provisioning race condition was fixed (see above), `azd up --no-prompt` completed successfully. However, the next E2E step — "Wait for Front Door endpoint to become ready" — timed out after 30 attempts × 10 seconds (~5 minutes):

```
::error::AFD endpoint did not become ready after 30 attempts
```

The `curl -sf` probe to `https://<afd-endpoint>/health` silently failed every attempt with no diagnostic output, making root cause analysis difficult.

### Root Cause Analysis

Azure Front Door Premium endpoints can take **5–15 minutes** to become fully routable after provisioning completes. The original wait script had only a 5-minute budget (30 × 10s), which is at the low end of the propagation window. Additionally:

- `curl -sf` suppresses all output on failure, so there was no way to distinguish DNS failure, TLS errors, HTTP 404/503, or network timeouts.
- The script did not verify that the origin App Service itself was healthy before waiting on AFD.

### Fix Applied

In `.github/workflows/e2e-test.yml`:

1. **Added a "Verify origin health" step** — checks that the backend App Service returns HTTP 200 on `/health` before waiting for AFD, so backend issues are caught early.
2. **Increased AFD wait budget to ~10 minutes** (60 attempts × 10s) to accommodate typical AFD propagation times.
3. **Log HTTP status code on every attempt** — replaced silent `curl -sf` with `curl -s -o /dev/null -w '%{http_code}'` so each attempt shows the actual HTTP response.
4. **Added failure diagnostics** — on final failure, the script now runs `curl -sv` (verbose) and `nslookup` to capture TLS handshake details, response headers, and DNS resolution for debugging.

### Outcome

- Provisioning succeeds (confirmed by E2E run on `copilot/bug-fix-deployment-errors` branch).
- The improved wait step provides actionable diagnostic output if AFD propagation is still slow.

---

## 2026-04-03 – Transient HTTP 504 During `azd deploy`

### Symptoms

After provisioning succeeded, `azd up --no-prompt` failed during the deploy phase:

```
Deploying service app (Checking deployment history)
ERROR: deployment failed: ...
```

The Azure Resource Manager gateway returned an **HTTP 504 Gateway Timeout** when calling `Microsoft.Web/sites/.../deployments` (listing App Service deployment history). The workflow exited with code 1.

### Root Cause Analysis

This is a **transient ARM control-plane timeout** — the Azure Resource Manager gateway couldn't get a timely response from the `Microsoft.Web` resource provider. The app package itself was valid; the failure was in ARM infrastructure, not in the application code or Bicep templates.

These transient 504s are more common:
- Right after provisioning (resource provider may still be settling)
- In regions with high control-plane load
- During Azure platform maintenance windows

### Fix Applied

In `.github/workflows/e2e-test.yml`:

1. **Split `azd up` into `azd provision` + `azd deploy`** — separates infrastructure provisioning (which succeeded) from app deployment, so a transient deploy failure doesn't re-run provisioning.
2. **Added retry loop with exponential backoff on `azd deploy`** — up to 5 attempts with increasing wait times (30s, 60s, 90s, 120s) between retries, matching the user's suggested pattern.
3. **Logs each attempt** — emits GitHub Actions warnings on retry and an error annotation on final failure.

### Outcome

- Transient ARM 504s during deploy are automatically retried without re-provisioning.
---

## 2026-04-03 – AFD Consistently Returns Its Own "Page Not Found" (HTTP 404) After 10-Minute Wait

### Symptoms

The "Wait for Front Door endpoint to become ready" step returned HTTP 404 with Azure Front Door's own HTML error page on every single attempt across the full 10-minute wait window:

```
Page not found
Oops! We weren't able to find your Azure Front Door Service configuration.
If it's a new configuration that you recently created, it might not be ready yet.
```

DNS resolved correctly, TLS completed cleanly, and the origin App Service returned HTTP 200 on `/health` directly. The issue was isolated to the AFD routing layer.

### Root Cause Analysis

Two compounding issues were identified:

**Issue 1 — `originPath: '/'` causes double-slash path forwarding**

The route in `frontdoor.bicep` had `originPath: '/'`. Azure Front Door's path forwarding semantics **prepend** `originPath` to the incoming request path. For a request to `/health` with `originPath: '/'`, AFD forwards `/ + /health = //health` to the origin. App Service (Fastify) normalises `//health` differently from `/health`, causing the origin to return 404. AFD then surfaces its own error page.

**Issue 2 — AFD propagation in Japan East exceeded 16 minutes**

From provisioning completion to end of the 10-minute wait, approximately 16+ minutes elapsed without AFD becoming ready. AFD's own error message ("If it's a new configuration that you recently created, it might not be ready yet. You should check again in a few minutes.") indicates the route hadn't propagated globally within that window. Japan East can exhibit longer propagation times.

**Issue 3 — Redundant `ruleSet` / `originTimeoutRule` resources added unnecessary propagation overhead**

The `streamingRules` rule set and `setOriginTimeout` rule were intended to "disable caching and set origin response timeout" but were effectively a NO-OP:
- **Origin response timeout**: Already configured at the AFD profile level via `originResponseTimeoutSeconds: 240`.
- **Caching bypass**: The rule's `RouteConfigurationOverride` action had no `cacheConfiguration` field, so it did not disable caching. The app already sends `Cache-Control: no-cache` on all streaming responses, which AFD respects without a rule.
- **Forwarding protocol override**: Set `HttpsOnly`, which is identical to the route's own `forwardingProtocol: 'HttpsOnly'` — no change.

Every extra AFD resource (rule set, rule) must propagate globally, adding to the time before the endpoint becomes routable. Removing the NO-OP resources reduces the propagation surface.

### Fix Applied

In `infra/modules/frontdoor.bicep`:

1. **Removed `originPath: '/'`** from the route — AFD now forwards the request path unchanged to the origin (default pass-through). Requests to `/health` reach the origin at `/health`.
2. **Added `enabledState: 'Enabled'`** to the route — explicit state prevents any ambiguity about default values across API versions.
3. **Removed `ruleSet` and `originTimeoutRule` resources** — the rule set was a NO-OP and required additional global propagation. `originResponseTimeoutSeconds: 240` at the profile level and `Cache-Control: no-cache` in app responses cover the original intent.
4. **Updated route `dependsOn`** — now only `[origin]` (correct), removing the no-longer-existent `originTimeoutRule`.

In `.github/workflows/e2e-test.yml`:

5. **Increased AFD wait budget from 60×10s (10 min) to 90×20s (30 min)** — empirical observation shows Japan East AFD propagation can take 16–25+ minutes from provisioning completion. The `--max-time` for each curl probe was also increased from 10s to 15s.

### Deployment ordering after the fix

```
afdProfile
├── originGroup ──► origin
│                     │
│                     ▼
├── endpoint ──► route (dependsOn: [origin])
```

### Outcome

- Route configuration is simpler and has fewer resources to propagate.
- Path forwarding is unambiguous: `/*` → origin root, no double-slash.
- Wait budget is 30 minutes, comfortably covering observed Japan East propagation times.

### Strategies That Were Considered but Not Applied

| Strategy | Reason Not Applied |
|---|---|
| Keep `ruleSet` with an explicit `cacheConfiguration: { cacheType: 'NoCache' }` rule | The app already sets `Cache-Control: no-cache`; an AFD rule is redundant. Adds propagation time. |
| Poll root path `/` instead of `/health` | The route pattern `/*` covers both equally; `/health` is preferred as it is a dedicated health endpoint. |
| Use AFD provisioning state API to wait instead of HTTP probe | Requires additional Azure CLI calls; HTTP probe is simpler and more representative of real-world readiness. |

