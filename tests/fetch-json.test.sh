#!/bin/bash
# Exercises the producer-side byte cap without touching the network by serving
# bodies over file:// URLs.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fetch-json.sh
source "$root_dir/scripts/fetch-json.sh"

work_dir=$(mktemp -d -t omarchy-bitcoin-bar-test-XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

failures=0

check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (expected %q, got %q)\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

body="$work_dir/body.json"
out="$work_dir/out.json"

# A body inside the cap is accepted verbatim.
printf '{"fastestFee":12}' >"$body"
status=0
fetch_capped "file://$body" "$out" 1024 5 || status=$?
check "small body accepted" "0" "$status"
check "small body preserved" '{"fastestFee":12}' "$(cat "$out")"

# A body larger than the cap is rejected and nothing is kept.
head -c 4096 /dev/zero | tr '\0' 'a' >"$body"
status=0
fetch_capped "file://$body" "$out" 1024 5 2>/dev/null || status=$?
check "oversized body rejected" "1" "$status"
check "oversized body discarded" "0" "$(wc -c <"$out")"

# A body exactly at the cap is still accepted: the cap is inclusive.
head -c 1024 /dev/zero | tr '\0' 'b' >"$body"
status=0
fetch_capped "file://$body" "$out" 1024 5 || status=$?
check "body at cap accepted" "0" "$status"
check "body at cap complete" "1024" "$(wc -c <"$out")"

# An empty body is a failure, not a successful empty parse.
: >"$body"
status=0
fetch_capped "file://$body" "$out" 1024 5 2>/dev/null || status=$?
check "empty body rejected" "1" "$status"

# The entry point rejects oversized responses before printing anything.
head -c 4096 /dev/zero | tr '\0' 'a' >"$body"
output=$(bash "$root_dir/scripts/fetch-json.sh" "file://$body" 1024 5 2>/dev/null) && status=0 || status=$?
check "cli rejects oversized" "1" "$status"
check "cli prints nothing on overflow" "" "$output"

# Valid JSON inside the cap round-trips through the entry point.
printf '{"count":7}' >"$body"
output=$(bash "$root_dir/scripts/fetch-json.sh" "file://$body" 1024 5)
check "cli emits valid json" '{"count":7}' "$output"

# Non-JSON inside the cap is rejected before it is emitted.
printf 'not json at all' >"$body"
output=$(bash "$root_dir/scripts/fetch-json.sh" "file://$body" 1024 5 2>/dev/null) && status=0 || status=$?
check "cli rejects non-json" "1" "$status"
check "cli prints nothing on non-json" "" "$output"

# Bad limits are refused rather than silently defaulted.
bash "$root_dir/scripts/fetch-json.sh" "file://$body" "not-a-number" 5 >/dev/null 2>&1 && status=0 || status=$?
check "cli rejects bad max-bytes" "2" "$status"
bash "$root_dir/scripts/fetch-json.sh" >/dev/null 2>&1 && status=0 || status=$?
check "cli requires a url" "2" "$status"

# Host failover: a URL on a known mempool.space host expands onto every known
# host, primary first, and the host that answered last is tried first. All of
# this is offline: only candidate ordering and state handling are exercised.
export XDG_STATE_HOME="$work_dir/state"

mapfile -t candidates < <(candidate_urls "https://mempool.space/api/mempool")
check "known host: primary first" "https://mempool.space/api/mempool" "${candidates[0]}"
check "known host: mirror second" "https://mempool.emzy.de/api/mempool" "${candidates[1]}"
check "known host: two candidates" "2" "${#candidates[@]}"

mapfile -t candidates < <(candidate_urls "https://mempool.emzy.de/api/v1/prices")
check "mirror url: primary kept" "https://mempool.space/api/v1/prices" "${candidates[0]}"

mapfile -t candidates < <(candidate_urls "https://api.coingecko.com/api/v3/x")
check "unknown url: untouched" "https://api.coingecko.com/api/v3/x" "${candidates[0]}"
check "unknown url: single candidate" "1" "${#candidates[@]}"

mkdir -p "$XDG_STATE_HOME/omarchy-bitcoin-bar"
printf 'mempool.emzy.de\n' >"$XDG_STATE_HOME/omarchy-bitcoin-bar/api-host"
mapfile -t candidates < <(candidate_urls "https://mempool.space/api/mempool")
check "remembered host first" "https://mempool.emzy.de/api/mempool" "${candidates[0]}"
check "primary still tried" "https://mempool.space/api/mempool" "${candidates[1]}"

# Only fixed endpoints may be remembered, so the state file can never redirect
# a request to a host this project does not ship.
rm -f "$XDG_STATE_HOME/omarchy-bitcoin-bar/api-host"
remember_host "mempool.emzy.de"
check "remember_host stores a known host" "mempool.emzy.de" "$(cat "$XDG_STATE_HOME/omarchy-bitcoin-bar/api-host")"
remember_host "example.com"
check "remember_host ignores unknown hosts" "mempool.emzy.de" "$(cat "$XDG_STATE_HOME/omarchy-bitcoin-bar/api-host")"
printf 'example.com\n' >"$XDG_STATE_HOME/omarchy-bitcoin-bar/api-host"
mapfile -t candidates < <(candidate_urls "https://mempool.space/api/mempool")
check "unknown remembered host ignored" "https://mempool.space/api/mempool" "${candidates[0]}"

if [ "$failures" -ne 0 ]; then
  printf 'fetch-json.sh: %s check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "fetch-json.sh: all tests passed"
