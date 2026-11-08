#!/bin/bash
# Tests for Scripts/check-mise-tools-registry.sh.
#
# Fully HERMETIC: every case points the check at a fixture written under $TMP
# through MISE_TOOLS_CONFIG. Nothing here runs mise or touches the network.
# The one deliberate exception is the last case, which runs the check against
# the repository's real mise.toml so a reintroduced vendor pin fails CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/Scripts/check-mise-tools-registry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

run() { MISE_TOOLS_CONFIG="$1" "$CHECK" > "$TMP/out" 2> "$TMP/err"; }

# 1. Registry-only tools, with tasks below them, pass. The tasks section is
#    there because a task body may legitimately mention a URL, and the check
#    must stop caring once it leaves [tools].
cat > "$TMP/clean.toml" <<'EOF'
[tools]
cmake = "4.4.5"
ninja = "1.13.2"
xcodegen = "2.46.0"

[tasks.fetch]
description = "download something"
run = "curl -fsSL https://example.invalid/x.tar.gz -o x.tar.gz"
url = "https://example.invalid"
EOF
run "$TMP/clean.toml" || fail "clean mise.toml was refused: $(cat "$TMP/err")"
pass "registry-only tools pass, and a URL in a task is not a tool pin"

# 2. The shape that broke CI: an http-backend table with per-platform URLs.
#    Each offending line is named, so the fix is a round trip.
cat > "$TMP/blink.toml" <<'EOF'
[tools]
cmake = "4.4.5"
[tools."http:blink"]
version = "0.1.3"
platforms.macos-arm64.url = "https://vendor.invalid/blink-arm64.gz"
platforms.macos-arm64.checksum = "sha256:00"
EOF
if run "$TMP/blink.toml"; then fail "http-backend table was accepted"; fi
grep -q 'blink.toml:3: tool pinned through the http backend' "$TMP/err" \
  || fail "table header not named with its line: $(cat "$TMP/err")"
grep -q 'blink.toml:5: tool carries its own download URL' "$TMP/err" \
  || fail "URL line not named with its line: $(cat "$TMP/err")"
pass "an http-backend table is refused, header and URL each named by line"

# 3. The same backend written inline in [tools], quoted or not.
cat > "$TMP/inline.toml" <<'EOF'
[tools]
"http:thing" = "1.0.0"
EOF
if run "$TMP/inline.toml"; then fail "inline quoted http pin was accepted"; fi
pass "an inline http pin is refused"

# 4. A URL under a non-http tool table is still a vendor dependency.
cat > "$TMP/url.toml" <<'EOF'
[tools]
[tools.thing]
version = "1.0.0"
url = "https://vendor.invalid/thing.tar.gz"
EOF
if run "$TMP/url.toml"; then fail "url under a tools table was accepted"; fi
grep -q 'url.toml:4: tool carries its own download URL' "$TMP/err" \
  || fail "URL not named: $(cat "$TMP/err")"
pass "a download URL under any tools table is refused"

# 4b. TOML the first cut missed: an indented key, an inline table, and
#     `url  =` with extra spacing are all valid ways to write the same pin.
cat > "$TMP/inline-table.toml" <<'EOF'
[tools]
  cmake = "4.4.5"
  "http:blink" = { version = "0.1.3", url  = "https://vendor.invalid/blink.gz" }
EOF
if run "$TMP/inline-table.toml"; then fail "indented inline-table http pin was accepted"; fi
grep -q 'inline-table.toml:3: tool pinned through the http backend' "$TMP/err" \
  || fail "inline-table key not named: $(cat "$TMP/err")"
grep -q 'inline-table.toml:3: tool carries its own download URL' "$TMP/err" \
  || fail "inline-table url not named: $(cat "$TMP/err")"
pass "an indented inline-table pin with spaced 'url  =' is refused on both counts"

# 4c. A comment under [tools] that happens to mention a URL is prose, not a
#     pin, and must not fail the check.
cat > "$TMP/comment.toml" <<'EOF'
[tools]
# The old pin had url = "https://vendor.invalid/x" here; see the learning.
cmake = "4.4.5"
    # indented remark: url = still not a pin
EOF
run "$TMP/comment.toml" || fail "a comment mentioning a URL was refused: $(cat "$TMP/err")"
pass "comments under [tools] are ignored"

# 5. A missing config fails closed with exit 2, not a quiet pass.
set +e
MISE_TOOLS_CONFIG="$TMP/absent.toml" "$CHECK" > /dev/null 2> "$TMP/err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing config exited $rc, expected 2"
grep -q 'cannot read' "$TMP/err" || fail "missing config not reported: $(cat "$TMP/err")"
pass "a missing mise.toml fails closed"

# 6. Live: the repository's own mise.toml must pass. This is the assertion
#    that bites if someone pins a vendor-hosted tool again.
"$CHECK" > /dev/null 2> "$TMP/err" || fail "the real mise.toml was refused: $(cat "$TMP/err")"
pass "the repository's mise.toml has no vendor-hosted pin"

echo "All check-mise-tools-registry tests passed."
