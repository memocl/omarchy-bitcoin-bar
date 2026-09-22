#!/bin/bash
# Fetches a JSON document with a hard cap on the number of bytes accepted.
# The cap is enforced while the body is received, so an oversized or endless
# response never reaches the disk, the parser, or stdout.
set -euo pipefail

DEFAULT_MAX_BYTES=262144
DEFAULT_MAX_TIME=15

# mempool.space-compatible API hosts, primary first. Mirrors expose the
# identical API and are only consulted when the primary does not answer, which
# happens on networks that drop traffic to the primary's addresses (ISP
# filtering, captive portals, broken routes) even though the API itself is
# healthy. Requests still go to fixed HTTPS endpoints only.
MEMPOOL_API_HOSTS=("mempool.space" "mempool.emzy.de")

# Script-scoped so the EXIT trap can still see it after main returns.
fetch_json_tmp=""

state_dir() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-bitcoin-bar"
}

# remembered_host prints the host that answered last, so a blocked primary costs
# one failed attempt per refresh instead of one per endpoint.
remembered_host() {
  local file host known
  file="$(state_dir)/api-host"
  [ -r "$file" ] || return 1
  host=$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$host" ] || return 1
  for known in "${MEMPOOL_API_HOSTS[@]}"; do
    if [ "$host" = "$known" ]; then
      printf '%s' "$host"
      return 0
    fi
  done
  return 1
}

# remember_host records a host that answered. Unknown hosts are ignored, so the
# file can only ever hold one of the fixed endpoints above.
remember_host() {
  local host=$1 dir file known
  for known in "${MEMPOOL_API_HOSTS[@]}"; do
    if [ "$host" = "$known" ]; then
      [ "$(remembered_host 2>/dev/null)" = "$host" ] && return 0
      dir=$(state_dir)
      file="$dir/api-host"
      mkdir -p "$dir" 2>/dev/null || return 0
      printf '%s\n' "$host" >"$file" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}

host_of_url() {
  local rest=${1#*://}
  printf '%s' "${rest%%/*}"
}

# candidate_urls <url>: one URL per line. A URL on any known host is rewritten
# onto every known host, the last host that answered first, so a blocked primary
# does not take the widget down. Anything else is passed through unchanged.
candidate_urls() {
  local url=$1 rest path host first
  local -a order=()

  case "$url" in
  https://mempool.space/* | https://mempool.emzy.de/*) ;;
  *)
    printf '%s\n' "$url"
    return 0
    ;;
  esac

  rest=${url#*://}
  path=${rest#*/}
  first=$(remembered_host) || first=""
  if [ -n "$first" ]; then
    order+=("$first")
  fi
  for host in "${MEMPOOL_API_HOSTS[@]}"; do
    if [ "$host" = "$first" ]; then
      continue
    fi
    order+=("$host")
  done
  for host in "${order[@]}"; do
    printf 'https://%s/%s\n' "$host" "$path"
  done
}

# fetch_one <url> <destination> <max_bytes> <max_time>
# Writes the body to destination and returns 0 only when the complete body
# arrived within the cap. Overflow leaves destination empty and returns 1.
fetch_one() {
  local url=$1 destination=$2 max_bytes=$3 max_time=$4
  local -a pipe_status
  local received

  # head -c stops reading at the cap, so curl is killed rather than allowed to
  # keep filling the file. pipefail is relaxed for the pipeline because that
  # early exit is an expected outcome, not a transport error.
  set +o pipefail
  curl -fsS --connect-timeout 5 --max-time "$max_time" --retry 1 --retry-delay 1 \
    --max-filesize "$max_bytes" "$url" |
    head -c "$((max_bytes + 1))" >"$destination"
  pipe_status=("${PIPESTATUS[@]}")
  set -o pipefail

  received=$(wc -c <"$destination")
  if [ "$received" -gt "$max_bytes" ]; then
    printf 'fetch-json: response from %s exceeded %s bytes\n' "$url" "$max_bytes" >&2
    : >"$destination"
    return 1
  fi

  # curl also aborts on its own --max-filesize, which can trip before head
  # reaches the cap. Either way a partial body must not survive: the only way
  # head ends the transfer early is overflow, so a non-zero curl status here is
  # always either overflow or a real transport error.
  if [ "${pipe_status[0]}" -ne 0 ] || [ "$received" -eq 0 ]; then
    : >"$destination"
    return 1
  fi
  return 0
}

# fetch_capped <url> <destination> <max_bytes> <max_time>
# Tries every candidate host and succeeds as soon as one returns a complete body
# inside the cap. destination is truncated by each attempt, so a failed host
# never leaves a partial body behind for the next one.
fetch_capped() {
  local url=$1 destination=$2 max_bytes=$3 max_time=$4
  local candidate

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if fetch_one "$candidate" "$destination" "$max_bytes" "$max_time"; then
      remember_host "$(host_of_url "$candidate")"
      return 0
    fi
  done < <(candidate_urls "$url")

  : >"$destination"
  return 1
}

is_positive_integer() {
  case $1 in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

main() {
  local url=${1:-}
  local max_bytes=${2:-$DEFAULT_MAX_BYTES}
  local max_time=${3:-$DEFAULT_MAX_TIME}

  if [ -z "$url" ]; then
    echo "usage: fetch-json.sh <url> [max-bytes] [max-time]" >&2
    exit 2
  fi
  if ! is_positive_integer "$max_bytes" || ! is_positive_integer "$max_time"; then
    echo "fetch-json: max-bytes and max-time must be positive integers" >&2
    exit 2
  fi

  fetch_json_tmp=$(mktemp -t omarchy-bitcoin-bar-json-XXXXXX)
  trap 'rm -f "${fetch_json_tmp:-}"' EXIT

  fetch_capped "$url" "$fetch_json_tmp" "$max_bytes" "$max_time" || exit 1
  # Validate before emitting so a truncated or malformed body is never printed.
  jq -e . "$fetch_json_tmp" >/dev/null 2>&1 || exit 1
  cat "$fetch_json_tmp"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi