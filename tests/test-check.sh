#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Offline tests for scripts/check.sh. Fake 'ssh' and 'curl' programs
# stand in for the network, so every failure mode runs without it.
#
# Half of these cases are rejections. The check must fail closed: a
# mistake that turns "could not tell" into "not visible" would make a
# workflow skip verification, and nobody investigates a skipped job.
#
# Usage: tests/test-check.sh

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"

passed=0
failed=0

# --- Fake network programs ----------------------------------------------------

cat > "$tmp/bin/ssh" << 'FAKE'
#!/usr/bin/env bash
# Logs its arguments and the mode of the key file, then answers as the
# test dictates: FAKE_SSH_RCS is a space-separated list of exit codes,
# one per call, the last repeated.
printf '%s\n' "ssh $*" >> "$FAKE_LOG"
keyfile=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = -i ]; then keyfile="${args[$((i + 1))]}"; fi
done
mode="$(stat -c %a "$keyfile" 2> /dev/null || stat -f %Lp "$keyfile")"
printf '%s\n' "keymode=$mode" >> "$FAKE_LOG"
n=$(($(cat "$FAKE_STATE/ssh" 2> /dev/null || echo 0) + 1))
echo "$n" > "$FAKE_STATE/ssh"
read -r -a rcs <<< "${FAKE_SSH_RCS:-0}"
idx=$((n - 1))
if [ "$idx" -ge "${#rcs[@]}" ]; then idx=$((${#rcs[@]} - 1)); fi
rc="${rcs[$idx]}"
if [ -n "${FAKE_SSH_SLEEP:-}" ]; then sleep "$FAKE_SSH_SLEEP"; fi
if [ -n "${FAKE_SSH_STDERR:-}" ]; then printf '%s\n' "$FAKE_SSH_STDERR" >&2; fi
if [ "$rc" -eq 0 ]; then printf '%s' "${FAKE_SSH_STDOUT:-}"; fi
exit "$rc"
FAKE

cat > "$tmp/bin/curl" << 'FAKE'
#!/usr/bin/env bash
# Answers the change request from FAKE_CURL_CODES (space-separated, one
# per call, the last repeated) and the version probe from
# FAKE_CURL_PROBE_CODE. FAKE_CURL_RCS and FAKE_CURL_PROBE_RC set curl's
# exit status after it has printed the code, as a transfer that fails
# after the headers arrive does. FAKE_CURL_PROBE_BODY replaces the probe
# body, and FAKE_CURL_STDERR is written to stderr on every call.
printf '%s\n' "curl $*" >> "$FAKE_LOG"
# Held in a variable: a '}' inside ${VAR-default} would end the expansion.
default_probe=")]}'
\"3.7.2\""
url='' out=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --url) url="${args[$((i + 1))]}" ;;
    --output) out="${args[$((i + 1))]}" ;;
  esac
done
case "$url" in
  */config/server/version)
    code="${FAKE_CURL_PROBE_CODE:-200}"
    body="${FAKE_CURL_PROBE_BODY-$default_probe}"
    rc="${FAKE_CURL_PROBE_RC:-0}"
    ;;
  *)
    n=$(($(cat "$FAKE_STATE/curl" 2> /dev/null || echo 0) + 1))
    echo "$n" > "$FAKE_STATE/curl"
    read -r -a codes <<< "${FAKE_CURL_CODES:-200}"
    read -r -a rcs <<< "${FAKE_CURL_RCS:-0}"
    idx=$((n - 1))
    if [ "$idx" -ge "${#codes[@]}" ]; then idx=$((${#codes[@]} - 1)); fi
    code="${codes[$idx]}"
    idx=$((n - 1))
    if [ "$idx" -ge "${#rcs[@]}" ]; then idx=$((${#rcs[@]} - 1)); fi
    rc="${rcs[$idx]}"
    body="${FAKE_CURL_BODY:-}"
    ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$code"
if [ -n "${FAKE_CURL_STDERR:-}" ]; then printf '%s\n' "$FAKE_CURL_STDERR" >&2; fi
if [ "$code" = 000 ]; then
  echo "curl: (7) Failed to connect" >&2
  exit 7
fi
exit "$rc"
FAKE
chmod +x "$tmp/bin/ssh" "$tmp/bin/curl"

# --- Harness ------------------------------------------------------------------

key='-----BEGIN TEST PRIVATE KEY-----
not-a-real-key
-----END TEST PRIVATE KEY-----'
stats0='{"type":"stats","rowCount":0,"runTimeMilliseconds":2,"moreChanges":false}'
stats1='{"type":"stats","rowCount":1,"runTimeMilliseconds":2,"moreChanges":false}'
row() { printf '{"project":"sandbox","number":%s,"status":"%s"}\n' "$1" "$2"; }

out='' rc=0
# run [VAR=value ...]: later assignments override the defaults.
run() {
  : > "$tmp/output"
  : > "$tmp/summary"
  : > "$tmp/log"
  rm -f "$tmp/state"/*
  set +e
  out="$(env \
    PATH="$tmp/bin:$PATH" \
    GITHUB_OUTPUT="$tmp/output" \
    GITHUB_STEP_SUMMARY="$tmp/summary" \
    FAKE_LOG="$tmp/log" FAKE_STATE="$tmp/state" \
    RETRY_DELAY=0 \
    INPUT_CHANGE_NUMBER=12345 \
    INPUT_MODE=ssh \
    INPUT_HOST=gerrit.example.org \
    INPUT_USERNAME=voter \
    INPUT_KEY="$key" \
    INPUT_KNOWN_HOSTS='[gerrit.example.org]:29418 ssh-ed25519 AAAAtest' \
    INPUT_GERRIT_URL=https://gerrit.example.org/infra \
    "$@" bash "$script" 2>&1)"
  rc=$?
  set -e
}

ok() {
  passed=$((passed + 1))
  echo "ok   - $1"
}
bad() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  while IFS= read -r line; do
    echo "       | $line"
  done <<< "$out"
}

# check DESCRIPTION CONDITION...: CONDITION is a command run as is.
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

exit_is() { [ "$rc" -eq "$1" ]; }
output_has() { grep -qx "$1" "$tmp/output"; }
output_lacks_visible() { ! grep -q '^visible=' "$tmp/output"; }
out_has() { grep -qF -- "$1" <<< "$out"; }
out_lacks() { ! grep -qF -- "$1" <<< "$out"; }
log_has() { grep -qF -- "$1" "$tmp/log"; }
count_is() { [ "$(cat "$tmp/state/$1" 2> /dev/null || echo 0)" -eq "$2" ]; }
never_called() { [ ! -e "$tmp/state/$1" ]; }

# --- SSH: verdicts ------------------------------------------------------------

run FAKE_SSH_STDOUT="$(row 12345 NEW)
$stats1"
check 'ssh: visible NEW change' exit_is 0
check 'ssh: visible=true' output_has 'visible=true'
check 'ssh: status=NEW' output_has 'status=NEW'

run FAKE_SSH_STDOUT="$(row 12345 MERGED)
$stats1"
check 'ssh: merged change is visible' output_has 'visible=true'
check 'ssh: merged status reported' output_has 'status=MERGED'

run FAKE_SSH_STDOUT="$(row 12345 ABANDONED)
$stats1"
check 'ssh: abandoned change is visible' output_has 'visible=true'

run FAKE_SSH_STDOUT="$stats0"
check 'ssh: unreadable change is a verdict, not an error' exit_is 0
check 'ssh: visible=false' output_has 'visible=false'
check 'ssh: status empty when not visible' output_has 'status='

run FAKE_SSH_STDOUT="$stats0" INPUT_FAIL_IF_NOT_VISIBLE=true
check 'ssh: fail-if-not-visible fails the step' exit_is 1
check 'ssh: output still written before failing' output_has 'visible=false'

run FAKE_SSH_STDOUT="$(row 12345 NEW)
$stats1"
check 'ssh: argv separates the host from options' \
  log_has "-- gerrit.example.org gerrit query --format=JSON change:12345"
check 'ssh: connects as the named user' log_has ' -l voter '
check 'ssh: uses the default port' log_has ' -p 29418 '
check 'ssh: verifies the host key' log_has 'StrictHostKeyChecking=yes'
check 'ssh: key file is private to the owner' log_has 'keymode=600'
check 'ssh: key never reaches the log' out_lacks 'not-a-real-key'
check 'ssh: summary table written' grep -q '^| 12345 | ssh | true | NEW |' "$tmp/summary"

# --- SSH: failures never read as "not visible" --------------------------------

run FAKE_SSH_RCS=255 FAKE_SSH_STDERR='Permission denied (publickey).'
check 'ssh: rejected credential fails' exit_is 1
check 'ssh: rejected credential is not retried' count_is ssh 1
check 'ssh: failure writes no verdict' output_lacks_visible

run FAKE_SSH_RCS='255 0' FAKE_SSH_STDERR='Connection reset' \
  FAKE_SSH_STDOUT="$(row 12345 NEW)
$stats1"
check 'ssh: transient failure then success' exit_is 0
check 'ssh: transient failure is retried' count_is ssh 2

run FAKE_SSH_RCS=255 FAKE_SSH_STDERR='Connection timed out'
check 'ssh: persistent failure fails' exit_is 1
check 'ssh: gives up after three attempts' count_is ssh 3
check 'ssh: persistent failure writes no verdict' output_lacks_visible

run FAKE_SSH_STDOUT="$(row 12345 NEW)"
check 'ssh: missing stats line fails' exit_is 1
check 'ssh: missing stats writes no verdict' output_lacks_visible

run FAKE_SSH_STDOUT='not json'
check 'ssh: garbage response fails' exit_is 1

run FAKE_SSH_STDOUT=''
check 'ssh: empty response fails' exit_is 1

run FAKE_SSH_STDOUT="$(row 99999 NEW)
$stats1"
check 'ssh: a row for another change fails' exit_is 1

run FAKE_SSH_STDOUT="$stats1"
check 'ssh: rowCount without a row fails' exit_is 1

run FAKE_SSH_STDOUT="$(row 12345 NEW)
$stats0"
check 'ssh: a row with rowCount 0 fails' exit_is 1

no_injected_command() { ! grep -q '^::set-output' <<< "$out"; }

run FAKE_SSH_RCS=255 \
  FAKE_SSH_STDERR=$'::set-output name=visible::true\nPermission denied'
check 'ssh: stderr cannot inject a workflow command' no_injected_command

# Copilot review finding: without timeout(1), a stalled query had no
# deadline at all. The fake answers only after FAKE_SSH_SLEEP seconds.
run INPUT_TIMEOUT=1 FAKE_SSH_SLEEP=4 FAKE_SSH_STDOUT="$(row 12345 NEW)
$stats1"
check 'ssh: a stalled query is cut off at the deadline' exit_is 1
check 'ssh: ... and retried like any transport failure' count_is ssh 3
check 'ssh: ... and writes no verdict' output_lacks_visible
check 'ssh: ... and says why' out_has 'timed out after 1s'

# --- SSH: input validation (the network is never reached) ---------------------

run INPUT_CHANGE_NUMBER='1; rm -rf /'
check 'input: shell metacharacters in the change number fail' exit_is 1
check 'input: ... before ssh runs' never_called ssh

run INPUT_CHANGE_NUMBER=012345
check 'input: leading zero in the change number fails' exit_is 1

run INPUT_CHANGE_NUMBER=''
check 'input: empty change number fails' exit_is 1

run INPUT_CHANGE_NUMBER=$'1\n2'
check 'input: newline in the change number fails' exit_is 1

run INPUT_HOST='-oProxyCommand=touch_pwned'
check 'input: host that looks like an option fails' exit_is 1
check 'input: ... before ssh runs' never_called ssh

run INPUT_HOST='gerrit.example.org extra'
check 'input: host with a space fails' exit_is 1

run INPUT_USERNAME='-oProxyCommand=x'
check 'input: user name that looks like an option fails' exit_is 1

run INPUT_PORT=70000
check 'input: port above 65535 fails' exit_is 1

run INPUT_PORT=0
check 'input: port 0 fails' exit_is 1

run INPUT_PORT=abc
check 'input: non-numeric port fails' exit_is 1

run INPUT_KEY=''
check 'input: missing key fails' exit_is 1
check 'input: ... before ssh runs' never_called ssh

run INPUT_KEY='hunter2'
check 'input: a key that is not a private key fails' exit_is 1
check 'input: ... without echoing it' out_lacks 'hunter2'

run INPUT_KNOWN_HOSTS=''
check 'input: missing known_hosts fails' exit_is 1

run INPUT_MODE=telnet
check 'input: unknown mode fails' exit_is 1

run INPUT_FAIL_IF_NOT_VISIBLE=maybe
check 'input: non-boolean fail-if-not-visible fails' exit_is 1

run INPUT_TIMEOUT=0
check 'input: timeout of 0 fails' exit_is 1

run INPUT_TIMEOUT=301
check 'input: timeout above 300 fails' exit_is 1

# --- REST ---------------------------------------------------------------------

rest_body=")]}'
{\"_number\":12345,\"status\":\"NEW\",\"project\":\"sandbox\"}"

run INPUT_MODE=rest FAKE_CURL_BODY="$rest_body"
check 'rest: readable change is visible' output_has 'visible=true'
check 'rest: status reported' output_has 'status=NEW'
check 'rest: needs no SSH' never_called ssh
check 'rest: requests the change under the base path' \
  log_has 'https://gerrit.example.org/infra/changes/12345'
check 'rest: refuses redirects and plain http' log_has '--max-redirs 0 --proto =https'

run INPUT_MODE=rest FAKE_CURL_CODES=404
check 'rest: 404 with a confirmed server is not visible' output_has 'visible=false'
check 'rest: 404 verdict exits 0' exit_is 0

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_CODE=404
check 'rest: 404 from a wrong base URL fails' exit_is 1
check 'rest: ... and writes no verdict' output_lacks_visible

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_CODE=000
check 'rest: unreachable probe fails rather than concluding' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=401
check 'rest: anonymous access refused fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=403
check 'rest: 403 fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=301
check 'rest: a redirect fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES='503 200' FAKE_CURL_BODY="$rest_body"
check 'rest: 503 then 200 succeeds' output_has 'visible=true'
check 'rest: 503 is retried' count_is curl 2

run INPUT_MODE=rest FAKE_CURL_CODES=500
check 'rest: persistent 500 fails' exit_is 1
check 'rest: gives up after three attempts' count_is curl 3
check 'rest: persistent 500 writes no verdict' output_lacks_visible

run INPUT_MODE=rest FAKE_CURL_CODES=000
check 'rest: unreachable server fails' exit_is 1
check 'rest: unreachable server is retried' count_is curl 3

run INPUT_MODE=rest FAKE_CURL_BODY='<html>login</html>'
check 'rest: a 200 that is not JSON fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_BODY=")]}'
{\"_number\":99999,\"status\":\"NEW\"}"
check 'rest: a 200 for another change fails' exit_is 1

# Copilot review finding: the runner's .curlrc must not steer the request.
# curl honours -q only as its first argument.
curl_starts_with_q() { grep -q '^curl -q ' "$tmp/log"; }
run INPUT_MODE=rest FAKE_CURL_BODY="$rest_body"
check 'rest: curl ignores the runner configuration (-q first)' curl_starts_with_q
every_curl_starts_with_q() {
  [ "$(grep -c '^curl ' "$tmp/log")" -eq "$(grep -c '^curl -q ' "$tmp/log")" ]
}
run INPUT_MODE=rest FAKE_CURL_CODES=404
check 'rest: ... on the version probe as well' every_curl_starts_with_q

# Copilot review finding: curl can print a status, then fail mid-transfer.
run INPUT_MODE=rest FAKE_CURL_CODES=200 FAKE_CURL_RCS=28 FAKE_CURL_BODY="$rest_body"
check 'rest: a 200 followed by a curl failure is not a verdict' exit_is 1
check 'rest: ... it is retried as a transport failure' count_is curl 3
check 'rest: ... and writes no verdict' output_lacks_visible

run INPUT_MODE=rest FAKE_CURL_CODES='200 200' FAKE_CURL_RCS='28 0' \
  FAKE_CURL_BODY="$rest_body"
check 'rest: a curl failure then success recovers' output_has 'visible=true'

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_CODE=200 FAKE_CURL_PROBE_RC=28
check 'rest: a probe that prints 200 then fails is not confirmation' exit_is 1
check 'rest: ... and writes no verdict' output_lacks_visible

# Copilot review finding: a 200 at the probe path proves nothing by itself.
run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_BODY='<html>Sign in</html>'
check 'rest: an HTML 200 from the probe path fails' exit_is 1
check 'rest: ... and writes no verdict' output_lacks_visible

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_BODY=''
check 'rest: an empty 200 from the probe path fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_BODY="$(printf ')]}'"'"'\n{"version":"3.7.2"}')"
check 'rest: a JSON object instead of a version string fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_BODY="$(printf ')]}'"'"'\n""')"
check 'rest: an empty version string fails' exit_is 1

run INPUT_MODE=rest FAKE_CURL_CODES=404 FAKE_CURL_PROBE_BODY='"3.7.2"'
check 'rest: a bare version string without the XSSI prefix confirms' output_has 'visible=false'

# Copilot review finding: prefixing alone does not stop injection.
no_cr() { ! grep -q $'\r' <<< "$out"; }
no_legacy_marker() { ! grep -qF '##[' <<< "$out"; }
no_pwned_line() { ! grep -q '^::error::pwned' <<< "$out"; }

run INPUT_MODE=rest FAKE_CURL_CODES=000 \
  FAKE_CURL_STDERR=$'harmless\r::error::pwned\nmore ##[add-mask]secret text'
check 'inject: a carriage return cannot expose an unprefixed command (curl)' no_pwned_line
check 'inject: no carriage return survives (curl)' no_cr
check 'inject: the legacy ##[ marker is defused (curl)' no_legacy_marker
check 'inject: the text is still shown, minus the markers' out_has 'pwned'

run FAKE_SSH_RCS=255 \
  FAKE_SSH_STDERR=$'x\r::error::pwned\n##[set-env name=A]b\nPermission denied'
check 'inject: a carriage return cannot expose an unprefixed command (ssh)' no_pwned_line
check 'inject: no carriage return survives (ssh)' no_cr
check 'inject: the legacy ##[ marker is defused (ssh)' no_legacy_marker

run INPUT_MODE=rest INPUT_GERRIT_URL=http://gerrit.example.org/infra
check 'rest: plain http is refused' exit_is 1

run INPUT_MODE=rest INPUT_GERRIT_URL=https://gerrit.example.org/infra/
check 'rest: trailing slash is refused' exit_is 1

run INPUT_MODE=rest INPUT_GERRIT_URL=https://user:pw@gerrit.example.org
check 'rest: credentials in the URL are refused' exit_is 1

run INPUT_MODE=rest INPUT_GERRIT_URL='https://gerrit.example.org/?x=1'
check 'rest: a query string is refused' exit_is 1

run INPUT_MODE=rest INPUT_GERRIT_URL=''
check 'rest: missing URL fails' exit_is 1

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
