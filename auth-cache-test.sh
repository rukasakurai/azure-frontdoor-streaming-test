#!/usr/bin/env bash
# auth-cache-test.sh - Record how Azure Front Door reports cache status when an
# Authorization header suppresses caching.
#
# Front Door's docs say a request carrying an Authorization header isn't cached
# unless the response has a Cache-Control directive that allows caching, but they
# don't say which cache status such a response reports. This script measures it.
#
#   H1  Authorization + no origin Cache-Control  -> not cached, reported as
#       X-Cache: TCP_MISS (rather than PRIVATE_NOSTORE).
#   H2  Adding Cache-Control: public, max-age=300 restores caching for the same
#       authorized request.
#
# Three arms, one asset:
#
#   arm1  no Authorization,  no origin Cache-Control        -> expect cached
#   arm2  Authorization,     no origin Cache-Control        -> expect not cached
#   arm3  Authorization,     Cache-Control public,max-age=300 -> expect cached
#
# With no Cache-Control, Front Door caches for a random 1-3 days, so an arm can
# poison a later arm. Every arm therefore uses a unique path. Query strings can't
# be used for that: the static-test route runs with
# queryStringCachingBehavior=IgnoreQueryString, which is exactly why they are safe
# to use as per-request labels instead.
#
# Exit code reflects whether the experiment was conclusive, not whether the
# hypotheses held. A falsified hypothesis is a result, and is reported as such.
#
# Usage:
#   ./auth-cache-test.sh <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <AFD_URL> [DIRECT_URL]

set -euo pipefail

WORKSPACE_ID="${1:-}"
AFD_URL="${2:-}"
DIRECT_URL="${3:-}"

if [[ -z "$WORKSPACE_ID" || -z "$AFD_URL" ]]; then
  echo "Usage: $0 <LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID> <AFD_URL> [DIRECT_URL]" >&2
  exit 1
fi

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-30}"
REQUESTS_PER_ARM="${REQUESTS_PER_ARM:-3}"
PRIME_GAP_SECONDS="${PRIME_GAP_SECONDS:-5}"
ASSET="app.js"
RUN_ID="auth-cache-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"

# Not a credential. Front Door only needs the header to be present; the origin
# never inspects it.
AUTH_HEADER="Authorization: Bearer ${RUN_ID}-placeholder"

# arm|scenario|send-authorization|description
ARMS=(
  "arm1|no-cache-control|no|no Authorization, origin sends no Cache-Control"
  "arm2|no-cache-control|yes|Authorization, origin sends no Cache-Control"
  "arm3|cacheable|yes|Authorization, origin sends Cache-Control: public, max-age=300"
)

expected_rows=$(( ${#ARMS[@]} * REQUESTS_PER_ARM ))

header_value() {
  # $1 = raw response headers, $2 = header name
  awk -v want="$2" '
    BEGIN { found = "-" }
    {
      sub(/\r$/, "")
      if (tolower($0) ~ "^" tolower(want) ":") {
        found = substr($0, index($0, ":") + 2)
      }
    }
    END { print (found == "" ? "-" : found) }
  ' <<< "$1"
}

is_hit() {
  case "${1^^}" in
    TCP_HIT | TCP_REMOTE_HIT | TCP_PARTIAL_HIT | HIT | REMOTE_HIT | PARTIAL_HIT) return 0 ;;
    *) return 1 ;;
  esac
}

run_kql() {
  az monitor log-analytics query \
    --workspace "$WORKSPACE_ID" \
    --analytics-query "$1" \
    "${@:2}"
}

log_rows_query="AzureDiagnostics
| where TimeGenerated > ago(2h)
| where Category == \"FrontDoorAccessLog\"
| where requestUri_s contains \"${RUN_ID}\"
| extend Arm = extract(@\"-(arm[0-9]+)/\", 1, requestUri_s)
| extend Request = toint(extract(@\"[?&]req=([0-9]+)\", 1, requestUri_s))
| where isnotempty(Arm) and isnotnull(Request)"

if [[ -n "$DIRECT_URL" ]]; then
  echo "Verifying the origin omits Cache-Control for the no-cache-control scenario..."
  origin_headers="$(curl -fsS -D - -o /dev/null --max-time 20 \
    "${DIRECT_URL%/}/static-test/no-cache-control/${RUN_ID}-origin/${ASSET}")"
  origin_cache_control="$(header_value "$origin_headers" "Cache-Control")"
  echo "Origin Cache-Control: ${origin_cache_control}"
  if [[ "$origin_cache_control" != "-" ]]; then
    echo "Origin unexpectedly sent a Cache-Control header; arms 1 and 2 would not test what they claim." >&2
    exit 1
  fi
fi

echo
echo "Run id: $RUN_ID"
echo "Sending $REQUESTS_PER_ARM request(s) per arm to $AFD_URL"
for entry in "${ARMS[@]}"; do
  IFS='|' read -r arm _scenario _send_auth description <<< "$entry"
  echo "  ${arm}: ${description}"
done
echo

declare -A arm_cached_by_header
declare -A arm_suppressed_status

printf '%-6s %-4s %-16s %-6s %-28s %-8s\n' "ARM" "REQ" "X-CACHE" "AGE" "CACHE-CONTROL" "ENCODING"
printf '%-6s %-4s %-16s %-6s %-28s %-8s\n' "------" "----" "----------------" "------" "----------------------------" "--------"

for entry in "${ARMS[@]}"; do
  IFS='|' read -r arm scenario send_auth _description <<< "$entry"
  arm_path="/static-test/${scenario}/${RUN_ID}-${arm}/${ASSET}"
  arm_cached_by_header["$arm"]="no"

  for req in $(seq 1 "$REQUESTS_PER_ARM"); do
    curl_args=(-fsS -D - -o /dev/null --compressed --max-time 30)
    if [[ "$send_auth" == "yes" ]]; then
      curl_args+=(-H "$AUTH_HEADER")
    fi

    headers="$(curl "${curl_args[@]}" "${AFD_URL%/}${arm_path}?run=${RUN_ID}&req=${req}")"
    x_cache="$(header_value "$headers" "X-Cache")"
    age="$(header_value "$headers" "Age")"
    cache_control="$(header_value "$headers" "Cache-Control")"
    encoding="$(header_value "$headers" "Content-Encoding")"

    printf '%-6s %-4s %-16s %-6s %-28s %-8s\n' \
      "$arm" "$req" "$x_cache" "$age" "$cache_control" "$encoding"

    if (( req > 1 )) && is_hit "$x_cache"; then
      arm_cached_by_header["$arm"]="yes"
    fi
    if (( req > 1 )) && ! is_hit "$x_cache"; then
      arm_suppressed_status["$arm"]="$x_cache"
    fi

    if (( req < REQUESTS_PER_ARM )); then
      sleep "$PRIME_GAP_SECONDS"
    fi
  done
done

echo
echo "Waiting for $expected_rows Front Door access log rows..."
deadline=$((SECONDS + MAX_WAIT_SECONDS))
count="0"
while (( SECONDS < deadline )); do
  count="$(run_kql "${log_rows_query}
| summarize Count=count()" --query '[0].Count' -o tsv | tr -d '\r' || echo "0")"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= expected_rows )); then
    echo "Found $count matching FrontDoorAccessLog row(s)."
    break
  fi
  echo "Found ${count:-0}/$expected_rows rows; waiting ${POLL_SECONDS}s..."
  sleep "$POLL_SECONDS"
done

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < expected_rows )); then
  echo "Timed out waiting for Front Door access logs for run id: $RUN_ID" >&2
  echo "The experiment is inconclusive without the logged cacheStatus values." >&2
  exit 1
fi

echo
echo "Front Door access log cache status per request:"
run_kql "${log_rows_query}
| project Arm, Request, cacheStatus_s, httpStatusCode_s, timeTaken_s
| order by Arm asc, Request asc" -o table

echo
echo "Cache status observed after the priming request:"
run_kql "${log_rows_query}
| where Request > 1
| summarize Requests=count(), Statuses=make_set(cacheStatus_s) by Arm
| order by Arm asc" -o table

verdict="$(run_kql "${log_rows_query}
| where Request > 1
| extend IsHit = iff(cacheStatus_s in (\"HIT\", \"REMOTE_HIT\", \"PARTIAL_HIT\"), 1, 0)
| summarize
    Arm1Hits=sumif(IsHit, Arm == \"arm1\"),
    Arm2Hits=sumif(IsHit, Arm == \"arm2\"),
    Arm3Hits=sumif(IsHit, Arm == \"arm3\"),
    Arm2Status=strcat_array(make_set_if(cacheStatus_s, Arm == \"arm2\" and IsHit == 0), \",\")
| project Arm1Hits, Arm2Hits, Arm3Hits, Arm2Status" \
  --query '[[0].[Arm1Hits, Arm2Hits, Arm3Hits, Arm2Status]]' -o tsv | tr -d '\r')"

# The projection is wrapped in an extra list on purpose. az CLI only tab-joins TSV
# fields when the top-level result items are themselves lists; a bare
# '[0].[A, B, C]' multiselect prints one value per line instead.
IFS=$'\t' read -r arm1_hits arm2_hits arm3_hits arm2_status <<< "$verdict"
for var in arm1_hits arm2_hits arm3_hits; do
  [[ "${!var}" =~ ^[0-9]+$ ]] || printf -v "$var" '%s' "0"
done
if [[ "$arm2_status" == "None" ]]; then
  arm2_status=""
fi

echo
echo "=============================== RESULT ==============================="
printf '%-5s %-50s %-9s %s\n' "ARM" "SETUP" "LOG HITS" "X-CACHE SAYS CACHED"
printf '%-5s %-50s %-9s %s\n' "arm1" "control: no Authorization, no Cache-Control" \
  "$arm1_hits" "${arm_cached_by_header[arm1]:-n/a}"
printf '%-5s %-50s %-9s %s\n' "arm2" "Authorization, no Cache-Control" \
  "$arm2_hits" "${arm_cached_by_header[arm2]:-n/a}"
printf '%-5s %-50s %-9s %s\n' "arm3" "Authorization, Cache-Control public, max-age=300" \
  "$arm3_hits" "${arm_cached_by_header[arm3]:-n/a}"
echo
echo "Auth-suppressed cache status, X-Cache response header: ${arm_suppressed_status[arm2]:-none observed}"
echo "Auth-suppressed cache status, access log cacheStatus:  ${arm2_status:-none observed}"
echo

if (( arm1_hits == 0 )); then
  echo "INCONCLUSIVE: the unauthenticated control arm never cached, so arm 2 not caching"
  echo "proves nothing about the Authorization header." >&2
  exit 1
fi

if (( arm2_hits > 0 )); then
  echo "H1 FALSIFIED: an authorized request with no origin Cache-Control was cached."
else
  echo "H1 SUPPORTED: an authorized request with no origin Cache-Control was not cached,"
  echo "              reported as X-Cache=${arm_suppressed_status[arm2]:-unknown} / cacheStatus=${arm2_status:-unknown}."
fi

if (( arm3_hits > 0 )); then
  echo "H2 SUPPORTED: Cache-Control: public, max-age=300 restored caching for the same"
  echo "              authorized request."
else
  echo "H2 FALSIFIED: Cache-Control: public, max-age=300 did not restore caching for the"
  echo "              authorized request."
fi

echo "======================================================================"
echo "Experiment conclusive. Run id: $RUN_ID"
