# Azure Front Door Streaming Test

A minimal test harness to verify whether **Azure Front Door (Premium)** buffers or passes through streaming HTTP responses (SSE and NDJSON).

## Architecture

```mermaid
flowchart LR
    Client -->|direct| AppService["App Service\n(Node.js 20)"]
    Client -->|via AFD| AFD["Azure Front Door\n(Premium)"]
    AFD --> AppService
    AppService --> SSE["/sse – SSE stream"]
    AppService --> NDJSON["/ndjson – NDJSON stream"]
    AppService --> Health["/health – health probe"]
```

## Purpose

Azure Front Door is a global load-balancer/CDN. There is uncertainty about whether it buffers long-lived streaming responses (SSE, NDJSON) before forwarding them to clients. This repo deploys a Node.js server with two streaming endpoints, exposes them both directly and via AFD, and provides a shell script to measure per-chunk arrival times and detect buffering.

## Prerequisites

| Tool | Notes |
|------|-------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | Authenticated (`az login`) |
| [azd CLI](https://learn.microsoft.com/azure/developer-cli/install-azd) | ≥ 1.9 |
| Node.js 20 LTS | Local dev / building |
| bash or WSL2 | Running `test.sh` |
| curl | Included in most Linux/macOS/WSL2 environments |

## Quick Start

### 1. Deploy infrastructure

```bash
azd up
```

`azd up` provisions:
- Resource group
- App Service Plan (Linux B1)
- App Service (Node.js 20 LTS) with the Fastify server
- Azure Front Door Premium profile with a route forwarding `/*` to the App Service

It prints the `SERVICE_APP_URI` (direct URL) and `AFD_URI` at the end.

### 2. Run the streaming test

```bash
chmod +x test.sh
./test.sh <SERVICE_APP_URI> <AFD_URI>
```

Example:

```bash
./test.sh \
  https://app-abc123.azurewebsites.net \
  https://streaming-test-abc123.z01.azurefd.net
```

The script tests `/sse` and `/ndjson` against both URLs and prints a per-chunk timing table, then concludes with **PASS** or **FAIL**.

### 3. Tear down

```bash
azd down
```

## Endpoints

| Endpoint | Content-Type | Description |
|----------|-------------|-------------|
| `GET /sse` | `text/event-stream` | Sends 10 SSE events at 1-second intervals |
| `GET /ndjson` | `application/x-ndjson` | Sends 10 JSON lines at 1-second intervals |
| `GET /health` | `application/json` | Returns `{"status":"ok"}` – used by AFD health probe |

## Test Script Behaviour

`test.sh` accepts two positional arguments:

1. `DIRECT_URL` – base URL of the App Service
2. `AFD_URL` – base URL of the Azure Front Door endpoint

For each endpoint and each URL it:

1. Opens a streaming `curl -N` request
2. Records the elapsed time (in seconds) when each chunk arrives
3. Prints a comparison table with per-chunk arrival times and the delta between direct and AFD
4. Flags chunks where AFD lags more than **2 seconds** behind direct as `BATCHED`
5. Also detects total buffering if all AFD chunks arrive within 2 seconds of each other

**Exit code 0** = PASS, **exit code 1** = FAIL.

## Results

| Scenario | Expected | Observed |
|----------|----------|----------|
| SSE via AFD | Streaming (≤2 s lag per chunk) | ✅ Streaming — per-chunk Δ from −0.003 s to +0.007 s |
| NDJSON via AFD | Streaming (≤2 s lag per chunk) | ✅ Streaming — per-chunk Δ from +0.033 s to +0.068 s |

> Tested 2026-04-03 in Japan East. Azure Front Door Premium passes through SSE and NDJSON streams without buffering.

## Local Development

```bash
cd app
npm install
npm start
# Server listens on http://localhost:3000
```

Test locally:

```bash
curl -N http://localhost:3000/sse
curl -N http://localhost:3000/ndjson
```

## License

[MIT](LICENSE)