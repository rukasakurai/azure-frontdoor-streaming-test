#!/usr/bin/env bash
# cache-test.sh - Compare AFD cache MISS rates for fixed baseline and optimized endpoints.
#
# Usage:
#   ./cache-test.sh <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <BASELINE_AFD_URL> <OPTIMIZED_AFD_URL>

set -euo pipefail

WORKSPACE_ID="${1:-}"
BASELINE_AFD_URL="${2:-}"
OPTIMIZED_AFD_URL="${3:-}"

if [[ -z "$WORKSPACE_ID" || -z "$BASELINE_AFD_URL" || -z "$OPTIMIZED_AFD_URL" ]]; then
  echo "Usage: $0 <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <BASELINE_AFD_URL> <OPTIMIZED_AFD_URL>" >&2
  exit 1
fi

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-30}"
REQUESTS_PER_ENDPOINT="${REQUESTS_PER_ENDPOINT:-12}"
RUN_ID="cache-regression-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
ASSET_PATH="/static-test/query/app.js"

expected=$((REQUESTS_PER_ENDPOINT * 2))

query_count() {
  az monitor log-analytics query \
    --workspace "$WORKSPACE_ID" \
    --analytics-query "AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| where requestUri_s contains \"${RUN_ID}\"
| extend Path = tostring(parse_url(requestUri_s).Path)
| where (Path startswith \"/cache-baseline/\" and routingRuleName_s == \"baseline-route\")
    or (not(Path startswith \"/cache-baseline/\") and routingRuleName_s == \"default-route\")
| summarize Count=count()" \
    --query '[0].Count' \
    -o tsv | tr -d '\r'
}

echo "Generating cache comparison traffic with run id: $RUN_ID"
for i in $(seq 1 "$REQUESTS_PER_ENDPOINT"); do
  curl -fsS -o /dev/null --max-time 20 "${BASELINE_AFD_URL%/}${ASSET_PATH}?cacheRun=${RUN_ID}&variant=${i}"
  curl -fsS -o /dev/null --max-time 20 "${OPTIMIZED_AFD_URL%/}${ASSET_PATH}?cacheRun=${RUN_ID}&variant=${i}"
done

echo "Waiting for $expected Front Door access log rows..."
deadline=$((SECONDS + MAX_WAIT_SECONDS))
count="0"
while (( SECONDS < deadline )); do
  count="$(query_count || echo "0")"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= expected )); then
    echo "Found $count matching FrontDoorAccessLog row(s)."
    break
  fi
  echo "Found ${count:-0}/$expected rows; waiting ${POLL_SECONDS}s..."
  sleep "$POLL_SECONDS"
done

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < expected )); then
  echo "Timed out waiting for cache comparison logs for run id: $RUN_ID" >&2
  exit 1
fi

echo "Cache status by scenario:"
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| where requestUri_s contains \"${RUN_ID}\"
| extend Path = tostring(parse_url(requestUri_s).Path)
| extend Scenario = case(
    Path startswith \"/cache-baseline/\" and routingRuleName_s == \"baseline-route\", \"baseline-use-query-string\",
    routingRuleName_s == \"default-route\", \"optimized-ignore-query-string\",
    \"unexpected-route\")
| where Scenario != \"unexpected-route\"
| summarize
    Requests=count(),
    Misses=countif(cacheStatus_s == \"MISS\"),
    Hits=countif(cacheStatus_s in (\"HIT\", \"REMOTE_HIT\")),
    MissRate=round(100.0 * countif(cacheStatus_s == \"MISS\") / count(), 2),
    P95TimeTakenSec=percentile(todouble(timeTaken_s), 95)
  by Scenario, cacheStatus_s
| order by Scenario asc, cacheStatus_s asc" \
  -o table

passed="$(az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "let summary = AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| where requestUri_s contains \"${RUN_ID}\"
| extend Path = tostring(parse_url(requestUri_s).Path)
| extend Scenario = case(
    Path startswith \"/cache-baseline/\" and routingRuleName_s == \"baseline-route\", \"baseline-use-query-string\",
    routingRuleName_s == \"default-route\", \"optimized-ignore-query-string\",
    \"unexpected-route\")
| where Scenario != \"unexpected-route\"
| summarize Requests=count(), MissRateBasisPoints=toint(round(10000.0 * countif(cacheStatus_s == \"MISS\") / count(), 0)) by Scenario;
summary
| summarize
    BaselineRequests=maxif(Requests, Scenario == \"baseline-use-query-string\"),
    OptimizedRequests=maxif(Requests, Scenario == \"optimized-ignore-query-string\"),
    BaselineMissRate=maxif(MissRateBasisPoints, Scenario == \"baseline-use-query-string\"),
    OptimizedMissRate=maxif(MissRateBasisPoints, Scenario == \"optimized-ignore-query-string\")
| extend Passed = iff(BaselineRequests > 0 and OptimizedRequests > 0 and OptimizedMissRate <= BaselineMissRate, 1, 0)
| project Passed" \
  --query '[0].Passed' \
  -o tsv | tr -d '\r')"

if [[ "$passed" != "1" ]]; then
  echo "Optimized endpoint did not show a MISS rate less than or equal to baseline." >&2
  exit 1
fi

echo "Cache MISS-rate comparison passed."
