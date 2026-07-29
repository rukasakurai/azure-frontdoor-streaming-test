#!/usr/bin/env bash
# test.sh – Compare streaming behavior between direct App Service and Azure Front Door
#
# Usage:
#   ./test.sh <DIRECT_URL> <AFD_URL>
#
# Example:
#   ./test.sh https://app-xyz.azurewebsites.net https://streaming-test-abc.z01.azurefd.net

set -euo pipefail

DIRECT_URL="${1:-}"
AFD_URL="${2:-}"

if [[ -z "$DIRECT_URL" || -z "$AFD_URL" ]]; then
  echo "Usage: $0 <DIRECT_URL> <AFD_URL>" >&2
  exit 1
fi

PASS=true
THRESHOLD_SECONDS=2   # max allowed lag between direct and AFD per-chunk arrival

# ── helpers ────────────────────────────────────────────────────────────────────

expected_content_type() {
  local endpoint="$1"
  case "$endpoint" in
    /sse|/sse-agent) echo "text/event-stream" ;;
    /ndjson) echo "application/x-ndjson" ;;
    *) echo "" ;;
  esac
}

stream_parser() {
  local endpoint="$1"
  case "$endpoint" in
    /sse|/sse-agent) echo "sse" ;;
    /ndjson) echo "ndjson" ;;
    *) echo "line" ;;
  esac
}

validate_stream_headers() {
  local url="$1"
  local expected_type="$2"
  local headers
  local status
  local content_type

  headers="$(curl -sS -I --max-time 15 "$url" 2>/dev/null || true)"
  status="$(awk 'tolower($0) ~ /^http\// {code=$2} END{print code}' <<< "$headers")"
  content_type="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ {sub(/\r$/,""); value=substr($0,index($0,":")+2)} END{print value}' <<< "$headers")"

  if [[ "$status" != "200" ]]; then
    echo " ERROR: $url returned HTTP ${status:-unknown}; expected 200" >&2
    echo "$headers" >&2
    return 1
  fi

  if [[ -n "$expected_type" && "$content_type" != "$expected_type"* ]]; then
    echo " ERROR: $url returned Content-Type '${content_type:-unknown}'; expected ${expected_type}" >&2
    echo "$headers" >&2
    return 1
  fi
}

# Fetch a streaming endpoint and print elapsed seconds for each received chunk.
# Returns a newline-separated list of float timestamps (relative to request start).
stream_timestamps() {
  local url="$1"
  local parser="$2"

  # Record the epoch at start
  local t0
  t0="$(date +%s%N)"   # nanoseconds

  # Stream with curl; write each chunk to a temp file, flushing line by line
  curl -sS -N --max-time 120 "$url" 2>/dev/null | while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    case "$parser" in
      sse)
        [[ "$line" == data:* ]] || continue
        ;;
      ndjson)
        [[ "$line" == \{* ]] || continue
        ;;
    esac
    local tnow
    tnow="$(date +%s%N)"
    # elapsed in seconds with 3 decimal places
    awk -v t0="$t0" -v tnow="$tnow" 'BEGIN{printf "%.3f\n", (tnow-t0)/1e9}'
  done
}

# Compare two arrays of timestamps and decide pass/fail.
# (Comparison logic is implemented inline in run_test below.)

run_test() {
  local endpoint="$1"
  local expected_count="${2:-}"
  local direct_url="${DIRECT_URL%/}${endpoint}"
  local afd_url="${AFD_URL%/}${endpoint}"
  local content_type
  local parser
  content_type="$(expected_content_type "$endpoint")"
  parser="$(stream_parser "$endpoint")"

  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " Endpoint : $endpoint"
  echo "════════════════════════════════════════════════════════"
  echo " Fetching direct  : $direct_url"

  if ! validate_stream_headers "$direct_url" "$content_type"; then
    PASS=false
    return
  fi

  # Collect timestamps into arrays
  mapfile -t direct_ts < <(stream_timestamps "$direct_url" "$parser")
  echo " Direct chunks received : ${#direct_ts[@]}"

  echo " Fetching via AFD : $afd_url"
  if ! validate_stream_headers "$afd_url" "$content_type"; then
    PASS=false
    return
  fi

  mapfile -t afd_ts < <(stream_timestamps "$afd_url" "$parser")
  echo " AFD chunks received    : ${#afd_ts[@]}"

  if [[ -n "$expected_count" ]]; then
    if (( ${#direct_ts[@]} != expected_count || ${#afd_ts[@]} != expected_count )); then
      echo " ERROR: Expected $expected_count valid stream records, got direct=${#direct_ts[@]} AFD=${#afd_ts[@]}" >&2
      PASS=false
    fi
  fi

  # Print comparison table
  printf "\n %-6s  %-12s  %-12s  %-10s  %s\n" "Chunk" "Direct (s)" "AFD (s)" "Δ (s)" "Status"
  printf " %-6s  %-12s  %-12s  %-10s  %s\n" "------" "----------" "-------" "------" "------"

  local max_idx=$(( ${#direct_ts[@]} > ${#afd_ts[@]} ? ${#direct_ts[@]} : ${#afd_ts[@]} ))

  for (( i=0; i<max_idx; i++ )); do
    local d="${direct_ts[$i]:-N/A}"
    local a="${afd_ts[$i]:-N/A}"
    local delta="N/A"
    local status="?"

    if [[ "$d" != "N/A" && "$a" != "N/A" ]]; then
      delta="$(awk -v a="$a" -v d="$d" 'BEGIN{printf "%.3f", a-d}')"
      # Is this chunk "batched"? If AFD lag >> direct chunk time it arrived all at once.
      status="$(awk -v delta="$delta" -v thr="$THRESHOLD_SECONDS" \
        'BEGIN{print (delta+0 <= thr) ? "OK" : "BATCHED"}')"
      if [[ "$status" == "BATCHED" ]]; then
        PASS=false
      fi
    fi

    printf " %-6s  %-12s  %-12s  %-10s  %s\n" "$((i+1))" "$d" "$a" "$delta" "$status"
  done

  # Detect total-buffering: all AFD chunks arrive within 1 second of each other
  if (( ${#afd_ts[@]} >= 2 )); then
    local first="${afd_ts[0]}"
    local last="${afd_ts[${#afd_ts[@]}-1]}"
    local spread
    spread="$(awk -v f="$first" -v l="$last" 'BEGIN{printf "%.3f", l-f}')"
    echo ""
    echo " AFD chunk spread: ${spread}s  (direct spread: $(awk -v f="${direct_ts[0]:-0}" -v l="${direct_ts[${#direct_ts[@]}-1]:-0}" 'BEGIN{printf "%.3f", l-f}')s)"
    local batched
    batched="$(awk -v spread="$spread" 'BEGIN{print (spread+0 < 2) ? "yes" : "no"}')"
    if [[ "$batched" == "yes" ]]; then
      echo " ⚠  AFD delivered all chunks within 2 s – response appears BUFFERED"
      PASS=false
    fi
  fi
}

# ── main ───────────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Azure Front Door Streaming Test                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo " Direct URL : $DIRECT_URL"
echo " AFD URL    : $AFD_URL"
echo " Threshold  : ${THRESHOLD_SECONDS}s per-chunk lag"

run_test "/sse" 10
run_test "/ndjson" 10

# Test the /sse-agent endpoint if Microsoft Foundry is configured.
# The endpoint returns HTTP 503 when Foundry env vars are not set.
agent_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${DIRECT_URL%/}/sse-agent" 2>/dev/null || echo "000")
if [[ "$agent_status" != "503" && "$agent_status" != "000" ]]; then
  run_test "/sse-agent"
else
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " Endpoint : /sse-agent"
  echo "════════════════════════════════════════════════════════"
  echo " SKIPPED – Microsoft Foundry not configured (HTTP $agent_status)"
fi

echo ""
echo "────────────────────────────────────────────────────────────"
if [[ "$PASS" == "true" ]]; then
  echo " RESULT: PASS ✅  – AFD streamed chunks within ${THRESHOLD_SECONDS}s of direct"
else
  echo " RESULT: FAIL ❌  – AFD appears to buffer the response"
fi
echo "────────────────────────────────────────────────────────────"

[[ "$PASS" == "true" ]]
