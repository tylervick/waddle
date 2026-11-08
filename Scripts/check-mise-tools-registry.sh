#!/bin/bash
# Refuses a mise.toml whose [tools] table pins anything through mise's `http`
# backend, or carries a download URL of its own.
#
# The incident: mise.toml pinned the Blink review CLI as `[tools."http:blink"]`
# with four content-addressed URLs on the vendor's CDN (d637d00, 2026-09-19).
# Nothing in CI ran Blink, but mise-action installs EVERY tool in [tools], so
# when blink.review stopped resolving in DNS every cache-missing CI run died
# at "Install pinned CLI tools" before a single test ran: PR #331 from
# 2026-10-27 on, and main itself at the #330 merge (run 42158647888,
# 2026-11-06). Runs that hit the mise cache for an older mise.toml hash
# stayed green, which is why the break hid for weeks.
#
# A registry-backed tool (cmake, ninja, xcodegen, or an `aqua:`/`ubi:`/
# `github:` pin) is served from GitHub or a mirror the whole build already
# depends on. A raw URL is a second vendor standing between a push and a
# green build, and this repo has no developer-only tool worth that. If one is
# ever wanted, install it outside [tools] -- a task, or a developer's own
# mise config -- so CI never downloads it.
#
# Exit 0: no such pin. Exit 1: at least one, each named with its line. Exit 2:
# mise.toml missing or unreadable -- fail closed; a guard that cannot read its
# input has proved nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${MISE_TOOLS_CONFIG:-$ROOT/mise.toml}"

if [ ! -r "$CONFIG" ]; then
  echo "error: cannot read $CONFIG" >&2
  exit 2
fi

status=0
in_tools=0
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  # TOML allows leading whitespace before a key or a table header, and a
  # comment anywhere; compare the trimmed, uncommented text so neither
  # indentation nor a `# url = ...` remark changes the verdict.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    \#*) continue ;;
  esac
  case "$trimmed" in
    # Any table header decides whether the lines after it belong to [tools].
    # `[tools]` and `[tools."name"]`/`[tools.name]` do; `[tasks.x]`, `[env]`
    # and the rest do not.
    \[tools\]*|\[tools.*) in_tools=1 ;;
    \[*) in_tools=0 ;;
  esac
  if [ "$in_tools" -eq 1 ]; then
    case "$trimmed" in
      # The backend in the table name: [tools."http:blink"]
      \[tools.\"http:*|\[tools.http:*)
        echo "error: $CONFIG:$lineno: tool pinned through the http backend: $trimmed" >&2
        status=1 ;;
      # The backend in a key, as a plain pin or an inline table:
      # "http:blink" = "0.1.3", or "http:blink" = { version = "1", url = "..." }
      \"http:*|http:*)
        echo "error: $CONFIG:$lineno: tool pinned through the http backend: $trimmed" >&2
        status=1 ;;
    esac
    # A download URL of any shape under [tools]: `platforms.x.url = "..."`,
    # `url  =` with any spacing, or `url =` inside an inline table. Checked
    # separately from the key patterns so an inline-table pin is reported
    # for both reasons, and a URL under a non-http table for this one.
    if printf '%s\n' "$trimmed" | grep -Eq '(^|[[:space:]{,.])url[[:space:]]*='; then
      echo "error: $CONFIG:$lineno: tool carries its own download URL: $trimmed" >&2
      status=1
    fi
  fi
done < "$CONFIG"

if [ "$status" -ne 0 ]; then
  echo "error: every tool in [tools] is installed by CI; pin tools from a registry only (see docs/learnings/vendor-hosted-tool-pin-took-ci-down.md)" >&2
fi
exit "$status"
