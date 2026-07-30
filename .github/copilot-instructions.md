# Copilot Instructions

This repository is a minimal test harness for verifying whether Azure Front Door (Premium) buffers or passes through streaming HTTP responses (SSE and NDJSON).
It contains a Node.js/Fastify app with streaming endpoints, Bicep/azd infrastructure (App Service + Azure Front Door Premium), and a bash test script that compares per-chunk arrival times between direct and AFD-proxied requests.
All infrastructure is in `infra/` (Bicep), the app is in `app/`, and the test script is `test.sh` at the root.

Streaming is the primary question, but the same deployment is reused to probe Front Door **caching** behaviour. `log-test.sh`, `cache-test.sh`, and `auth-cache-test.sh` (also at the root) read the Front Door access log from Log Analytics. None run on a pull request — they need a live deployment. `log-test.sh` is wired into the manually dispatched `e2e-test.yml`; the other two are hand-run, for different reasons: `cache-test.sh` is a regression check not yet safe to automate because of an unresolved log-delivery gap, while `auth-cache-test.sh` is an experiment whose changed result is a finding rather than a failure. See [docs/auth-cache-result.md](../docs/auth-cache-result.md) for the cache experiment write-up.
