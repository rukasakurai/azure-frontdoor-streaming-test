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
#
# Optional environment variables:
#   AZ_SUBSCRIPTION    subscription holding the workspace, if not the az default
#   REQUESTS_PER_ARM   requests per arm (default 3)
#   PRIME_GAP_SECONDS  pause between requests (default 5)
#   MAX_WAIT_SECONDS   how long to wait for access logs to arrive (default 900)
#   POLL_SECONDS       log poll interval (default 30)

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
# Set when the workspace lives outside the az CLI's default subscription, which
# also fixes cross-tenant token errors from `az monitor log-analytics query`.
AZ_SUBSCRIPTION="${AZ_SUBSCRIPTION:-}"
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

# Cache-status vocabularies, split by how much we actually know about each value.
# CONFIRMED entries were observed in a real run of this script and their meaning is
# settled. UNINTERPRETED entries are documented by Microsoft but have never been seen
# here, so their hit/miss bucket is an assumption. Rather than guess, a run that
# encounters one stops and says so -- otherwise an unrecognised hit would silently be
# counted as a miss and the script would blame the control arm for the wrong reason.
#
#   https://learn.microsoft.com/en-us/azure/frontdoor/front-door-caching
XCACHE_HIT="TCP_HIT TCP_REMOTE_HIT"                            # confirmed 2026-07-29
XCACHE_MISS="TCP_MISS"                                         # confirmed 2026-07-29
XCACHE_UNINTERPRETED="TCP_PARTIAL_HIT PRIVATE_NOSTORE CONFIG_NOCACHE"

STATUS_HIT="HIT REMOTE_HIT"                                    # confirmed 2026-07-29
STATUS_MISS="MISS"                                             # confirmed 2026-07-29
STATUS_UNINTERPRETED="PARTIAL_HIT PRIVATE_NOSTORE CACHE_NOCONFIG N/A"

classify() {
  # $1 = observed value, $2 = hit vocabulary, $3 = miss vocabulary
  # prints hit | miss | unknown
  local value="${1^^}" word
  for word in $2; do
    if [[ "$value" == "$word" ]]; then
      echo "hit"
      return 0
    fi
  done
  for word in $3; do
    if [[ "$value" == "$word" ]]; then
      echo "miss"
      return 0
    fi
  done
  echo "unknown"
  return 0
}

run_kql() {
  local scope=()
  if [[ -n "$AZ_SUBSCRIPTION" ]]; then
    scope=(--subscription "$AZ_SUBSCRIPTION")
  fi
  az monitor log-analytics query \
    "${scope[@]}" \
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
unknown_xcache=()
missing_xcache=()

printf '%-6s %-4s %-16s %-6s %-8s %-28s %-8s\n' "ARM" "REQ" "X-CACHE" "AGE" "TIER" "CACHE-CONTROL" "ENCODING"
printf '%-6s %-4s %-16s %-6s %-8s %-28s %-8s\n' "------" "----" "----------------" "------" "--------" "----------------------------" "--------"

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
    # Undocumented, but it tracks the cache tier that answered: L1 is the edge and
    # pairs with TCP_HIT, L2 is the regional tier and pairs with TCP_REMOTE_HIT.
    tier="$(header_value "$headers" "X-Cache-Info")"

    printf '%-6s %-4s %-16s %-6s %-8s %-28s %-8s\n' \
      "$arm" "$req" "$x_cache" "$age" "$tier" "$cache_control" "$encoding"

    if (( req > 1 )); then
      # An absent X-Cache is a different condition from an unrecognised value: it means
      # the header wasn't observed at all, not that the vocabulary is incomplete. Only
      # the latter puts the classification in doubt. The access log is authoritative
      # either way; X-Cache is corroboration.
      if [[ -z "$x_cache" || "$x_cache" == "-" ]]; then
        missing_xcache+=("${arm}/req${req}")
      else
        case "$(classify "$x_cache" "$XCACHE_HIT" "$XCACHE_MISS")" in
          hit) arm_cached_by_header["$arm"]="yes" ;;
          miss) arm_suppressed_status["$arm"]="$x_cache" ;;
          unknown) unknown_xcache+=("${arm}/req${req}=${x_cache}") ;;
        esac
      fi
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
| project Arm, Request, cacheStatus_s, httpStatusCode_s, timeTaken_s, pop_s
| order by Arm asc, Request asc" -o table

echo
echo "Cache status observed after the priming request:"
run_kql "${log_rows_query}
| where Request > 1
| summarize Requests=count(), Statuses=make_set(cacheStatus_s), POPs=make_set(pop_s) by Arm
| order by Arm asc" -o table

verdict_rows="$(run_kql "${log_rows_query}
| where Request > 1
| project Arm, Request, cacheStatus_s, timeTaken_s
| order by Arm asc, Request asc" \
  --query '[].[Arm, Request, cacheStatus_s, timeTaken_s]' -o tsv | tr -d '\r')"

# Classification happens here rather than in KQL so there is exactly one vocabulary to
# audit, and so an unrecognised status is reported as such instead of being folded into
# "not a hit" by an `in (...)` clause.
declare -A arm_hits arm_miss_status arm_max_time
unknown_status=()
for entry in "${ARMS[@]}"; do
  IFS='|' read -r arm _rest <<< "$entry"
  arm_hits["$arm"]=0
  arm_max_time["$arm"]=0
done

while IFS=$'\t' read -r arm _req status taken; do
  [[ -n "$arm" ]] || continue
  case "$(classify "$status" "$STATUS_HIT" "$STATUS_MISS")" in
    hit) arm_hits["$arm"]=$(( ${arm_hits["$arm"]:-0} + 1 )) ;;
    miss) arm_miss_status["$arm"]="$status" ;;
    unknown) unknown_status+=("${arm}=${status}") ;;
  esac
  if awk -v a="$taken" -v b="${arm_max_time["$arm"]:-0}" 'BEGIN { exit !(a+0 > b+0) }'; then
    arm_max_time["$arm"]="$taken"
  fi
done <<< "$verdict_rows"

echo
echo "=============================== RESULT ==============================="
printf '%-5s %-50s %-9s %-11s %s\n' "ARM" "SETUP" "LOG HITS" "MAX SEC" "X-CACHE SAYS CACHED"
printf '%-5s %-50s %-9s %-11s %s\n' "arm1" "control: no Authorization, no Cache-Control" \
  "${arm_hits[arm1]}" "${arm_max_time[arm1]}" "${arm_cached_by_header[arm1]:-n/a}"
printf '%-5s %-50s %-9s %-11s %s\n' "arm2" "Authorization, no Cache-Control" \
  "${arm_hits[arm2]}" "${arm_max_time[arm2]}" "${arm_cached_by_header[arm2]:-n/a}"
printf '%-5s %-50s %-9s %-11s %s\n' "arm3" "Authorization, Cache-Control public, max-age=300" \
  "${arm_hits[arm3]}" "${arm_max_time[arm3]}" "${arm_cached_by_header[arm3]:-n/a}"
echo "MAX SEC is the slowest post-priming timeTaken, an origin-fetch signal independent"
echo "of the cache-status vocabulary."
echo
echo "Auth-suppressed cache status, X-Cache response header: ${arm_suppressed_status[arm2]:-none observed}"
echo "Auth-suppressed cache status, access log cacheStatus:  ${arm_miss_status[arm2]:-none observed}"
echo

if (( ${#missing_xcache[@]} > 0 )); then
  echo "Note: no X-Cache header on ${#missing_xcache[@]} post-priming response(s):" \
    "${missing_xcache[*]}"
  echo "Reading the access log's cacheStatus only for those."
  echo
fi

if (( ${#unknown_status[@]} > 0 || ${#unknown_xcache[@]} > 0 )); then
  echo "INCONCLUSIVE: observed a cache status this script has no validated meaning for." >&2
  (( ${#unknown_status[@]} > 0 )) && printf '  access log: %s\n' "${unknown_status[@]}" >&2
  (( ${#unknown_xcache[@]} > 0 )) && printf '  X-Cache:    %s\n' "${unknown_xcache[@]}" >&2
  echo "Resolve what that value means before reading anything into the arms. Treating it" >&2
  echo "as a non-hit would misreport the control arm as 'never cached'." >&2
  exit 1
fi

if (( ${arm_hits[arm1]} == 0 )); then
  echo "INCONCLUSIVE: the unauthenticated control arm never cached, so arm 2 not caching"
  echo "proves nothing about the Authorization header." >&2
  exit 1
fi

if (( ${arm_hits[arm2]} > 0 )); then
  echo "H1 FALSIFIED: an authorized request with no origin Cache-Control was cached."
else
  echo "H1 SUPPORTED: an authorized request with no origin Cache-Control was not cached,"
  echo "              reported as X-Cache=${arm_suppressed_status[arm2]:-unknown} / cacheStatus=${arm_miss_status[arm2]:-unknown}."
  if ! awk -v a="${arm_max_time[arm2]}" -v b="${arm_max_time[arm1]}" 'BEGIN { exit !(a+0 > b+0) }'; then
    echo "WARNING: arm 2 was classified as uncached but was not slower than the cached"
    echo "         control arm. The timing signal contradicts the status vocabulary."
  fi
fi

if (( ${arm_hits[arm3]} > 0 )); then
  echo "H2 SUPPORTED: Cache-Control: public, max-age=300 restored caching for the same"
  echo "              authorized request."
else
  echo "H2 FALSIFIED: Cache-Control: public, max-age=300 did not restore caching for the"
  echo "              authorized request."
fi

echo "======================================================================"
echo "Experiment conclusive. Run id: $RUN_ID"
echo "Caching is per-POP; check the POPs column above before generalising from one run."
