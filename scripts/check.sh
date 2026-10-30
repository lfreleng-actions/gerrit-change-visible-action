#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Decide whether a Gerrit change is visible to the querying account.
#
# Reads its inputs from INPUT_* environment variables (see action.yaml)
# and writes 'visible' and 'status' to $GITHUB_OUTPUT.
#
# Exit status: 0 for a verdict, visible or not (unless
# INPUT_FAIL_IF_NOT_VISIBLE is 'true'); 1 for anything else. A failure
# to decide is never reported as "not visible": that would let a broken
# check read as a reason to skip verification.
#
# RETRY_DELAY (seconds, default 3) exists so the tests need not wait.

set -euo pipefail

readonly MAX_ATTEMPTS=3
retry_delay="${RETRY_DELAY:-3}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir

# Every message is fixed text. Input values never appear in one, so
# nothing a caller supplies can reach a workflow command.
fail() {
  printf '::error title=Gerrit change visibility::%s\n' "$1"
  exit 1
}

# require NAME VALUE REGEX: the value is present, free of control
# characters (a newline would pass many anchored patterns) and matches.
require() {
  local name=$1 value=$2 regex=$3
  if [ -z "$value" ]; then
    fail "Input '$name' is required."
  fi
  if [[ $value =~ [[:cntrl:]] ]] || ! [[ $value =~ $regex ]]; then
    fail "Input '$name' is not in the expected form."
  fi
}

# Show a captured stream without letting it reach the runner as a
# workflow command. Prefixing every line stops a line starting '::', but
# the runner also splits on a bare carriage return, which would expose
# an unprefixed '::' after it, and reads the legacy '##[' marker
# anywhere in a line. So drop every control character except the
# newline, defuse the marker, and only then prefix.
show() {
  local label=$1 file=$2
  if [ -s "$file" ]; then
    LC_ALL=C tr -d '\000-\011\013-\037\177' < "$file" |
      LC_ALL=C sed -e 's/##\[/# #[/g' -e "s/^/$label: /"
  fi
}

pause() {
  if [ "$retry_delay" != 0 ]; then
    sleep "$retry_delay"
  fi
}

# --- Inputs -----------------------------------------------------------------

mode="${INPUT_MODE:-ssh}"
case "$mode" in
  ssh | rest) ;;
  *) fail "Input 'mode' must be 'ssh' or 'rest'." ;;
esac

change="${INPUT_CHANGE_NUMBER:-}"
require 'gerrit-change-number' "$change" '^[1-9][0-9]{0,9}$'

timeout_s="${INPUT_TIMEOUT:-30}"
require 'timeout' "$timeout_s" '^[0-9]{1,3}$'
if [ "$((10#$timeout_s))" -lt 1 ] || [ "$((10#$timeout_s))" -gt 300 ]; then
  fail "Input 'timeout' must be between 1 and 300 seconds."
fi
timeout_s="$((10#$timeout_s))"

fail_if_not_visible="${INPUT_FAIL_IF_NOT_VISIBLE:-false}"
case "$fail_if_not_visible" in
  true | false) ;;
  *) fail "Input 'fail-if-not-visible' must be 'true' or 'false'." ;;
esac

if [[ ! $retry_delay =~ ^[0-9]{1,3}$ ]]; then
  fail "RETRY_DELAY must be a whole number of seconds."
fi

if ! command -v python3 > /dev/null 2>&1; then
  fail "python3 is required and was not found."
fi

work="$(mktemp -d)"
readonly work
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# --- SSH mode ---------------------------------------------------------------

run_ssh() {
  local -a cmd=(
    ssh -F /dev/null
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$work/known_hosts"
    -o GlobalKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o "ConnectTimeout=$timeout_s"
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o HostKeyAlgorithms=+ssh-rsa
    -i "$work/key"
    -p "$port"
    -l "$username"
    -- "$host"
    gerrit query --format=JSON "change:$change"
  )
  # ConnectTimeout bounds only connection setup, and keepalives do not
  # stop a responsive server whose query has stalled. Enforce the
  # deadline on the whole attempt, the same way on every runner:
  # timeout(1) is absent from some, such as stock macOS.
  python3 "$script_dir/run_with_timeout.py" "$timeout_s" -- "${cmd[@]}"
}

query_ssh() {
  host="${INPUT_HOST:-}"
  username="${INPUT_USERNAME:-}"
  port="${INPUT_PORT:-29418}"
  local key="${INPUT_KEY:-}" known_hosts="${INPUT_KNOWN_HOSTS:-}"

  require 'host' "$host" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  if [ "${#host}" -gt 253 ]; then
    fail "Input 'host' is not in the expected form."
  fi
  require 'username' "$username" '^[A-Za-z0-9_][A-Za-z0-9._-]*$'
  require 'port' "$port" '^[0-9]{1,5}$'
  if [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
    fail "Input 'port' must be between 1 and 65535."
  fi
  port="$((10#$port))"

  if [ -z "$key" ]; then
    fail "Input 'key' is required in mode 'ssh'."
  fi
  if [[ $key != *"PRIVATE KEY"* ]]; then
    fail "Input 'key' does not look like an SSH private key."
  fi
  if [ -z "$known_hosts" ]; then
    fail "Input 'known_hosts' is required in mode 'ssh'."
  fi

  (
    umask 077
    printf '%s\n' "$key" > "$work/key"
    printf '%s\n' "$known_hosts" > "$work/known_hosts"
  )

  local attempt=1 rc
  while :; do
    set +e
    run_ssh > "$work/response" 2> "$work/stderr"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    show ssh "$work/stderr"
    # A rejected credential or host key will not mend itself.
    if grep -q -E 'Permission denied|Host key verification failed|HOST IDENTIFICATION HAS CHANGED' "$work/stderr"; then
      fail "Gerrit rejected the connection; check the key, user name and known_hosts."
    fi
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      fail "Could not query Gerrit over SSH after $MAX_ATTEMPTS attempts."
    fi
    attempt=$((attempt + 1))
    pause
  done
}

# --- REST mode --------------------------------------------------------------

# GET a URL, retrying only failures that say nothing about the change.
# Leaves the status in http_code and the body in $work/response.
#
# curl can print a status and still fail: the headers arrive, then the
# transfer times out. So a nonzero exit is a transport failure whatever
# status it printed, and is reported as 000.
http_code=''
fetch() {
  local attempt=1 curl_rc
  while :; do
    curl_rc=0
    # -q must come first: it stops curl reading the runner's .curlrc,
    # where a 'user', an Authorization header or 'insecure' would turn
    # this anonymous, certificate-verified request into something else.
    http_code="$(curl -q --silent --show-error \
      --max-time "$timeout_s" --max-redirs 0 \
      --proto '=https' --tlsv1.2 \
      --header 'Accept: application/json' \
      --output "$work/response" --write-out '%{http_code}' \
      --url "$1" 2> "$work/stderr")" || curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [[ ! $http_code =~ ^[0-9]{3}$ ]]; then
      http_code=000
    fi
    case "$http_code" in
      000 | 429 | 5[0-9][0-9]) ;;
      *) return 0 ;;
    esac
    show http "$work/stderr"
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    pause
  done
}

query_rest() {
  local url="${INPUT_GERRIT_URL:-}"
  # https only, no credentials, query string or fragment, no trailing slash.
  require 'gerrit-url' "$url" \
    '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$'

  fetch "$url/changes/$change"
  case "$http_code" in
    200) return 0 ;;
    404) ;;
    000) fail "Could not reach Gerrit after $MAX_ATTEMPTS attempts." ;;
    401 | 403)
      fail "Gerrit refused anonymous access (HTTP $http_code); use mode 'ssh'."
      ;;
    *)
      fail "Gerrit answered HTTP $http_code to the change request."
      ;;
  esac

  # 404 means both "no such change" and "not a Gerrit REST root": a base
  # URL missing its path prefix (/infra, /gerrit) gets the same answer
  # for every change. Only a server that answers its version request
  # here may declare the change not visible.
  #
  # A 200 alone proves little: a proxy or a login page can answer one
  # for any path. The body must be a version string.
  fetch "$url/config/server/version"
  if [ "$http_code" != 200 ]; then
    fail "No such change, and the server did not confirm gerrit-url (HTTP $http_code); check the path prefix."
  fi
  if ! python3 "$script_dir/parse_response.py" version "$work/response" > /dev/null 2> "$work/parse_error"; then
    show parser "$work/parse_error"
    fail "No such change, and gerrit-url did not answer like a Gerrit server; check the path prefix."
  fi
  not_found=true
}

# --- Query and interpret ----------------------------------------------------

not_found=false
case "$mode" in
  ssh) query_ssh ;;
  rest) query_rest ;;
esac

visible=false
status=''
if [ "$not_found" = false ]; then
  if ! parsed="$(python3 "$script_dir/parse_response.py" "$mode" "$change" "$work/response" 2> "$work/parse_error")"; then
    show parser "$work/parse_error"
    fail "Gerrit returned a response this action cannot interpret."
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      visible) visible="$value" ;;
      status) status="$value" ;;
    esac
  done <<< "$parsed"
fi

if [ "$visible" != true ] && [ "$visible" != false ]; then
  fail "The response parser returned an unexpected verdict."
fi

{
  echo "visible=$visible"
  echo "status=$status"
} >> "${GITHUB_OUTPUT:-/dev/null}"

{
  echo '### Gerrit change visibility'
  echo
  echo '| Change | Mode | Visible | Status |'
  echo '| ------ | ---- | ------- | ------ |'
  echo "| $change | $mode | $visible | ${status:--} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$visible" = true ]; then
  echo "Change $change is visible (status $status), mode $mode."
else
  echo "Change $change is not visible to this account, mode $mode."
  if [ "$fail_if_not_visible" = true ]; then
    fail "Change $change is not visible."
  fi
fi
