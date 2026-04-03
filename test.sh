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

# Fetch a streaming endpoint and print elapsed seconds for each received chunk.
# Returns a newline-separated list of float timestamps (relative to request start).
stream_timestamps() {
  local url="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  # Record the epoch at start
  local t0
  t0="$(date +%s%N)"   # nanoseconds

  # Stream with curl; write each chunk to a temp file, flushing line by line
  curl -sS -N --max-time 30 "$url" 2>/dev/null | while IFS= read -r line; do
    # Skip empty lines and SSE comment/field prefixes that carry no data
    [[ -z "$line" ]] && continue
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
  local direct_url="${DIRECT_URL%/}${endpoint}"
  local afd_url="${AFD_URL%/}${endpoint}"

  echo ""
  echo "════════════════════════════════════════════════════════"
  echo " Endpoint : $endpoint"
  echo "════════════════════════════════════════════════════════"
  echo " Fetching direct  : $direct_url"

  # Collect timestamps into arrays
  mapfile -t direct_ts < <(stream_timestamps "$direct_url")
  echo " Direct chunks received : ${#direct_ts[@]}"

  echo " Fetching via AFD : $afd_url"
  mapfile -t afd_ts < <(stream_timestamps "$afd_url")
  echo " AFD chunks received    : ${#afd_ts[@]}"

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

run_test "/sse"
run_test "/ndjson"

echo ""
echo "────────────────────────────────────────────────────────────"
if [[ "$PASS" == "true" ]]; then
  echo " RESULT: PASS ✅  – AFD streamed chunks within ${THRESHOLD_SECONDS}s of direct"
else
  echo " RESULT: FAIL ❌  – AFD appears to buffer the response"
fi
echo "────────────────────────────────────────────────────────────"

[[ "$PASS" == "true" ]]
