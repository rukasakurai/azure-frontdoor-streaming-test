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
| Removing `originPath: '/'` from the route | Valid configuration; not related to the root cause |

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
- Each retry attempt is logged with attempt number and wait time for debuggability.
