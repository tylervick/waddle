#!/bin/bash
# Refuses a testflight.yml that could push the build-<N> tag with the job
# token again.
#
# The job token (GITHUB_TOKEN) may not create or update a ref whose workflow
# files differ from the default branch's head unless it holds the `workflows`
# permission, which the `permissions:` block cannot grant. A nightly release
# never noticed: it tagged main's head. An on-merge release tags the commit it
# built, and main moves past that commit while the archive runs; build 277
# (CI run 37097820909) was uploaded and then refused its tag with "refusing
# to allow a GitHub App to create or update workflow
# `.github/workflows/app-store-listing.yml` without `workflows` permission",
# after three workflow-touching merges landed in the window. The tag is now
# pushed with RELEASE_TAG_TOKEN, a fine-grained token that has the scope. See
# docs/learnings/job-token-cannot-tag-a-commit-main-moved-past.md.
#
# Three things keep it that way, and none fails loudly on its own:
#
#   1. No job in testflight.yml grants `contents: write`. The only write the
#      file ever made was that push; a grant reappearing is a regression to
#      it, or a new push that will meet the same refusal.
#   2. Every actions/checkout in testflight.yml sets persist-credentials:
#      false, so a `git push` with no credential of its own finds no job
#      token lying in .git/config to use.
#   3. Every `git push` in testflight.yml lives in a step whose `env:` names
#      RELEASE_TAG_TOKEN -- the credential the askpass helper answers with.
#
# There is no skip path. The input is a tracked file; unreadable is a failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so the test suite can point the guard at fixtures.
WORKFLOW="${RELEASE_TAG_TOKEN_CHECK_FILE:-$ROOT/.github/workflows/testflight.yml}"

violations=0
err() {
    echo "error: $1" >&2
    violations=$((violations + 1))
}

if [ ! -r "$WORKFLOW" ]; then
    echo "error: cannot read $WORKFLOW" >&2
    exit 1
fi

# 1. No contents: write anywhere in the file (job or workflow level).
if grep -nE '^[[:space:]]*contents:[[:space:]]*write[[:space:]]*$' "$WORKFLOW" >/dev/null; then
    line="$(grep -nE '^[[:space:]]*contents:[[:space:]]*write[[:space:]]*$' "$WORKFLOW" | head -n 1 | cut -d: -f1)"
    err "$WORKFLOW:$line grants contents: write. Nothing in the release workflow may push with the job token; the tag is pushed with RELEASE_TAG_TOKEN (see the permissions note on the release job)"
fi

# 2 and 3, in one pass over the steps. A step begins at a six-space `- `;
# inside it, `with:` and `env:` open blocks whose keys sit at ten spaces, and
# a `run:` block's lines sit at ten or more. awk emits one line per finding
# so the shell can count them without a subshell swallowing the counter.
findings="$(awk '
    function flush() {
        if (is_checkout && !pc_false)
            printf "checkout step at line %d does not set persist-credentials: false\n", step_line
        if (has_push && !has_token)
            printf "step at line %d runs git push without RELEASE_TAG_TOKEN in its env\n", step_line
        is_checkout = 0; pc_false = 0; has_push = 0; has_token = 0; block = ""
    }
    /^      - / { flush(); step_line = NR }
    /^      - uses:[[:space:]]*actions\/checkout@/ { is_checkout = 1 }
    /^        with:/ { block = "with"; next }
    /^        env:/  { block = "env";  next }
    /^        [a-z-]+:/ { block = "" }
    block == "with" && /^          persist-credentials:[[:space:]]*false[[:space:]]*$/ { pc_false = 1 }
    block == "env"  && /^          RELEASE_TAG_TOKEN:/ { has_token = 1 }
    /git push/ && !/^[[:space:]]*#/ { has_push = 1 }
    END { flush() }
' "$WORKFLOW")"
if [ -n "$findings" ]; then
    while IFS= read -r f; do err "$WORKFLOW: $f"; done <<< "$findings"
fi

if [ "$violations" -ne 0 ]; then
    echo "check-release-tag-token: $violations problem(s)" >&2
    exit 1
fi

echo "check-release-tag-token: ok - no contents: write, every checkout drops the job token, every git push carries RELEASE_TAG_TOKEN"
