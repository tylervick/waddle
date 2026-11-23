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
# It also holds .config/mise.toml to the tools on NON_BINARY_TOOLS below (uv):
# that file ships no release and keys no build cache, so a build tool pinned
# there would change the build silently.
#
# Exit 0: no such pin. Exit 1: at least one, each named with its file and line.
# Exit 2: mise.toml (or a config found beside it) missing or unreadable -- fail closed; a guard that cannot read its
# input has proved nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Every file mise loads [tools] from in this checkout, not just mise.toml:
# .config/mise.toml holds the tools that never reach the binary (uv, issue
# #454), and a pin moved into any other location mise reads is installed by CI
# just the same. mise.toml itself must exist; the rest are read when present.
# MISE_TOOLS_CONFIG names one file instead (the suite's fixtures);
# MISE_TOOLS_ROOT points the directory scan elsewhere.
CONFIGS=()
if [ -n "${MISE_TOOLS_CONFIG:-}" ]; then
  CONFIGS=("$MISE_TOOLS_CONFIG")
else
  dir="${MISE_TOOLS_ROOT:-$ROOT}"
  CONFIGS=("$dir/mise.toml")
  for f in "$dir"/.mise.toml "$dir"/mise.*.toml "$dir"/.mise.*.toml \
           "$dir"/mise/config.toml "$dir"/.mise/config.toml \
           "$dir"/.config/mise.toml "$dir"/.config/mise.*.toml \
           "$dir"/.config/mise/config.toml "$dir"/.config/mise/mise.toml \
           "$dir"/.config/mise/conf.d/*.toml; do
    if [ -f "$f" ]; then CONFIGS+=("$f"); fi
  done
fi

for CONFIG in "${CONFIGS[@]}"; do
  if [ ! -r "$CONFIG" ]; then
    echo "error: cannot read $CONFIG" >&2
    exit 2
  fi
done

# .config/mise.toml is for tools no build step runs. Scripts/release-due.sh
# excludes it, so a change there ships no TestFlight build, and neither build
# cache keys on it, so a change there rebuilds nothing. A build tool pinned
# there would therefore change the build without either -- so the file may
# pin only the tools named here (review of PR #473, round 2). Add to this list
# only a tool that no build, archive or engine script, and no Xcode build
# phase, ever runs.
NON_BINARY_TOOLS=" uv "

status=0
allow_status=0
for CONFIG in "${CONFIGS[@]}"; do
in_tools=0
plain_tools=0
lineno=0
non_binary=0
case "$CONFIG" in */.config/mise.toml|.config/mise.toml) non_binary=1 ;; esac
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
    \[tools\]*) in_tools=1; plain_tools=1 ;;
    \[tools.*) in_tools=1; plain_tools=0 ;;
    \[*) in_tools=0; plain_tools=0 ;;
  esac
  # The allowlist: which tool does this line pin, if any? A `[tools.name]`
  # table header, or a `name = ...` key directly under `[tools]` (a key under
  # a `[tools.name]` table is that tool's version or options, not a tool).
  if [ "$non_binary" -eq 1 ] && [ "$in_tools" -eq 1 ]; then
    tool=""
    case "$trimmed" in
      \[tools.*)
        tool="${trimmed#\[tools.}"; tool="${tool%%]*}" ;;
      \[*) ;;
      *=*)
        if [ "$plain_tools" -eq 1 ]; then tool="${trimmed%%=*}"; fi ;;
    esac
    tool="$(printf '%s' "$tool" | tr -d '"'"'"' \t')"
    if [ -n "$tool" ]; then
      case "$NON_BINARY_TOOLS" in
        *" $tool "*) ;;
        *) echo "error: $CONFIG:$lineno: pins '$tool', which is not on the non-binary list ($(echo $NON_BINARY_TOOLS)). This file is excluded from Scripts/release-due.sh and keys no build cache, so a build tool here would change the build without shipping it or rebuilding the engine. Put build tools in the root mise.toml" >&2
           allow_status=1 ;;
      esac
    fi
  fi
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
done

if [ "$status" -ne 0 ]; then
  echo "error: every tool in [tools] is installed by CI; pin tools from a registry only (see docs/learnings/vendor-hosted-tool-pin-took-ci-down.md)" >&2
fi
if [ "$status" -ne 0 ] || [ "$allow_status" -ne 0 ]; then
  exit 1
fi
exit 0
