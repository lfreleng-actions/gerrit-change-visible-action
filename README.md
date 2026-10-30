<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🔎 Gerrit Change Visible Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/gerrit-change-visible-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/gerrit-change-visible-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/gerrit-change-visible-action)
<!-- prettier-ignore-end -->

Reports whether a Gerrit change is visible to the account that will
vote on it, so a workflow can skip a change it cannot read instead of
failing on it.

## gerrit-change-visible-action

A change that Gerrit's dispatcher announces but the voting account
cannot read, typically a private change, fails every later step with
`Not found: <number>`. Gerrit's private change refs do not replicate to
GitHub either, so even a more privileged account could not check the
change out. Asking first lets the workflow stand down.

## Usage Example

<!-- markdownlint-disable MD046 -->

As the voting account, over SSH. This is the production form: it
answers for the account that clears and sets the vote.

```yaml
jobs:
  visibility:
    runs-on: ubuntu-latest
    outputs:
      visible: ${{ steps.check.outputs.visible }}
    steps:
      - name: "Is the change visible to the voting account?"
        id: check
        uses: lfreleng-actions/gerrit-change-visible-action@<SHA>  # <version>
        with:
          gerrit-change-number: ${{ inputs.GERRIT_CHANGE_NUMBER }}
          host: ${{ vars.GERRIT_SERVER }}
          username: ${{ vars.GERRIT_SSH_REQUIRED_USER }}
          key: ${{ secrets.GERRIT_SSH_REQUIRED_PRIVKEY }}
          known_hosts: ${{ vars.GERRIT_KNOWN_HOSTS }}

  verify:
    needs: visibility
    if: needs.visibility.outputs.visible == 'true'
    # ...
```

Anonymously, over REST. It needs no credential, so it can run where
secrets are unavailable, such as a pull request from a fork:

```yaml
      - uses: lfreleng-actions/gerrit-change-visible-action@<SHA>  # <version>
        with:
          mode: rest
          gerrit-change-number: "12345"
          gerrit-url: https://gerrit.linuxfoundation.org/infra
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                 | Required | Default | Description                                                                                                |
| -------------------- | -------- | ------- | ---------------------------------------------------------------------------------------------------------- |
| gerrit-change-number | True     |         | Change number: digits, no leading zero                                                                     |
| mode                 | False    | `ssh`   | `ssh` (as the voting account) or `rest` (anonymous)                                                        |
| host                 | ssh      |         | Gerrit SSH host name                                                                                       |
| port                 | False    | `29418` | Gerrit SSH port                                                                                            |
| username             | ssh      |         | Gerrit SSH user name                                                                                       |
| key                  | ssh      |         | SSH private key of the account                                                                             |
| known_hosts          | ssh      |         | `known_hosts` entry for the host; for a non-default port, as `ssh-keyscan -p` writes it: `[host]:port ...` |
| gerrit-url           | rest     |         | Base URL: https, no trailing slash, with any path prefix (`/infra`, `/gerrit`)                             |
| fail-if-not-visible  | False    | `false` | Fail the step when the change is not visible                                                               |
| timeout              | False    | `30`    | Seconds allowed for each attempt, 1 to 300                                                                 |

<!-- markdownlint-enable MD013 -->

The SSH input names match
[`gerrit-review-action`](https://github.com/lfreleng-actions/gerrit-review-action),
and a caller passes the same values to both.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name    | Description                                                              |
| ------- | ------------------------------------------------------------------------ |
| visible | `true` when the account can read the change, otherwise `false`           |
| status  | `NEW`, `MERGED` or `ABANDONED` when visible; empty when not visible      |

<!-- markdownlint-enable MD013 -->

## Implementation Details

### Verdicts and errors

The action separates three outcomes, and the first two are
verdicts:

| Outcome                                        | Step      | `visible`   |
| ---------------------------------------------- | --------- | ----------- |
| Change readable                                | passes    | `true`      |
| Change unreadable (private, or no such change) | passes    | `false`     |
| Anything else                                  | **fails** | not written |

"Anything else" covers a refused credential, an unreachable server, a
wrong base URL, an HTTP error, and a response the action cannot read.
Reporting any of these as "not visible" would let a broken check read
as a reason to skip verification, so none of them does. The action retries
transient failures (a dropped connection, HTTP 429 or 5xx) up to three
times. It never retries a rejected credential or host key.

A change is visible in **any** status. A merged change reports
`MERGED` and an abandoned one `ABANDONED`. This matters for changes
that merge within seconds of the dispatch.

### SSH mode

Runs `gerrit query --format=JSON change:<number>` as the named
account, with strict host key checking against the `known_hosts` value
supplied. The `timeout` input limits the whole attempt, including the
connection, so a server that accepts the connection and then stalls
cannot hold the step. A small Python runner enforces it the same way on
every platform, because `timeout(1)` is missing from some, such as
stock macOS. This is the account whose votes matter, which makes it the
production semantic: Gerrit can hide a change from this account that
anonymous users can read, or the reverse.

### REST mode

Anonymous `GET <gerrit-url>/changes/<number>`. It reports what an
anonymous user sees, which may differ from the voting account, so use
it for tests and for repositories without credentials, not as a
substitute for SSH mode in a voting workflow.

Gerrit answers `404` both for a missing or private change and for a
base URL that lacks its path prefix, which would make every change look
unreadable. On a `404` the action also asks the server for
`/config/server/version`, and declares "not visible" when the answer is
a version string. An error, a failed transfer, or a 200 that is not a
version (a proxy or a login page can answer one for any path) fails the
step and names the base URL as the suspect.

### Security notes

- Every input reaches the script through `env`, never by interpolation
  into a shell block, and the script checks it against a strict pattern
  before use. Values never appear in error messages.
- The script writes the SSH key to a private temporary directory
  (mode 600), never to `~/.ssh`, and removes it when the step ends. SSH
  ignores the runner's own configuration (`-F /dev/null`).
- REST mode refuses plain HTTP, redirects, URLs carrying credentials or
  a query string, and ignores the runner's `.curlrc`, so a `user`, an
  Authorization header or `insecure` there cannot change what the check
  sends or verifies.
- Before the action shows `ssh` or `curl` output, it drops every
  control character except the newline (a bare carriage return would
  expose an unprefixed `::` to the runner), defuses the legacy `##[`
  marker, and prefixes each line. A hostile server cannot inject a
  workflow command.

### Network access

Under `step-security/harden-runner` in block mode, allow the Gerrit
host: `<host>:29418` for SSH, `<host>:443` for REST.

## Notes

The tests run offline against fake `ssh` and `curl` programs
(`tests/test-check.sh`) and exercise the response parser directly
(`tests/test_parse_response.py`). The `testing.yaml` workflow also runs
the action in REST mode against the live LF Gerrit.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/gerrit-change-visible-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/gerrit-change-visible-action/main.svg
