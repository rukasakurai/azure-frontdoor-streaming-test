# Copilot Instructions

This repository is a minimal test harness for verifying whether Azure Front Door (Premium) buffers or passes through streaming HTTP responses (SSE and NDJSON).
It contains a Node.js/Fastify app with streaming endpoints, Bicep/azd infrastructure (App Service + Azure Front Door Premium), and a bash test script that compares per-chunk arrival times between direct and AFD-proxied requests.
All infrastructure is in `infra/` (Bicep), the app is in `app/`, and the test script is `test.sh` at the root.
