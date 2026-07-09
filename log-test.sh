#!/usr/bin/env bash
# log-test.sh - Verify Azure Front Door access logs are queryable in Log Analytics.
#
# Usage:
#   ./log-test.sh <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <AFD_URL>

set -euo pipefail

WORKSPACE_ID="${1:-}"
AFD_URL="${2:-}"

if [[ -z "$WORKSPACE_ID" || -z "$AFD_URL" ]]; then
  echo "Usage: $0 <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <AFD_URL>" >&2
  exit 1
fi

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-30}"
RUN_ID="kql-regression-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
AFD_HEALTH="${AFD_URL%/}/health?kqlRun=${RUN_ID}"

required_columns='("requestUri_s", "timeTaken_s", "cacheStatus_s")'

query_count() {
  az monitor log-analytics query \
    --workspace "$WORKSPACE_ID" \
    --analytics-query "AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| where requestUri_s contains \"${RUN_ID}\"
| summarize Count=count()" \
    --query '[0].Count' \
    -o tsv
}

echo "Generating AFD traffic with run id: $RUN_ID"
for i in 1 2 3; do
  curl -fsS -o /dev/null --max-time 20 "$AFD_HEALTH&request=$i"
done

echo "Waiting for Front Door access logs in Log Analytics..."
deadline=$((SECONDS + MAX_WAIT_SECONDS))
count="0"
while (( SECONDS < deadline )); do
  count="$(query_count | tr -d '\r' || echo "0")"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    echo "Found $count matching FrontDoorAccessLog row(s)."
    break
  fi
  echo "No matching logs yet; waiting ${POLL_SECONDS}s..."
  sleep "$POLL_SECONDS"
done

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
  echo "Timed out waiting for FrontDoorAccessLog rows for run id: $RUN_ID" >&2
  exit 1
fi

echo "Checking required AzureDiagnostics columns..."
found_columns="$(az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| getschema
| where ColumnName in ${required_columns}
| summarize Found=dcount(ColumnName)" \
  --query '[0].Found' \
  -o tsv | tr -d '\r')"

if [[ "$found_columns" != "3" ]]; then
  echo "Expected 3 required columns, found ${found_columns:-0}." >&2
  az monitor log-analytics query \
    --workspace "$WORKSPACE_ID" \
    --analytics-query "AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| getschema
| project ColumnName, ColumnType
| order by ColumnName asc" \
    -o table
  exit 1
fi

echo "Running recent-window KQL regression query..."
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query "AzureDiagnostics
| where Category == \"FrontDoorAccessLog\"
| where TimeGenerated > ago(2h)
| where requestUri_s contains \"${RUN_ID}\"
| extend Path = tostring(parse_url(requestUri_s).Path), TimeTakenSec = todouble(timeTaken_s)
| extend Path = iff(isempty(Path), \"/\", Path)
| summarize Requests = count(), MaxTimeTakenSec = max(TimeTakenSec), P95TimeTakenSec = percentile(TimeTakenSec, 95) by Path, cacheStatus_s
| order by MaxTimeTakenSec desc" \
  -o table

echo "Running fixed-window acceptance query..."
az monitor log-analytics query \
  --workspace "$WORKSPACE_ID" \
  --analytics-query 'AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated between (datetime(2026-06-30 00:00:00) .. datetime(2026-06-30 23:59:59))
| extend Path = tostring(parse_url(requestUri_s).Path), TimeTakenSec = todouble(timeTaken_s)
| extend Path = iff(isempty(Path), "/", Path)
| summarize Requests = count(), MaxTimeTakenSec = max(TimeTakenSec), P95TimeTakenSec = percentile(TimeTakenSec, 95) by Path, cacheStatus_s
| order by MaxTimeTakenSec desc' \
  -o table

echo "KQL regression test passed."
