#!/bin/bash
# Refuses a workflow job that calls a reusable workflow which reads
# `${{ secrets.* }}` without passing it any secrets.
#
# A called workflow receives NO secrets unless its caller hands them over --
# named under `secrets:`, or all of them with `secrets: inherit`. That holds
# even when the called job declares an `environment:` whose secrets it means
# to use: the environment decides which VALUES the names resolve to, but the
# names only reach the called run if the caller passed them. The first
# on-merge TestFlight release (CI run 37060983966, the merge of PR #317) hit
# exactly this: the deployment to `app-store` was recorded, every secret in
# the called job was the empty string, and the signing step failed with
# `SecKeychainItemImport: One or more parameters passed to a function were not
# valid` -- an error that names neither secrets nor the caller. See
# docs/learnings/called-workflow-receives-no-secrets-without-inherit.md.
#
# The check is static: for every job whose `uses:` names a workflow in this
# repository's .github/workflows/, if that workflow references
# `${{ secrets.` anywhere, the calling job must have a `secrets:` key.
# A called workflow that reads no secrets needs none passed, and is not a
# finding.
#
# There is no skip path. Every input is a tracked file; an unreadable called
# workflow is a failure, not an absence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so the test suite can point the guard at fixtures instead of the
# real tree. Callers in CI pass nothing.
WORKFLOWS_DIR="${CALLED_WORKFLOW_CHECK_DIR:-$ROOT/.github/workflows}"

violations=0
checked=0
err() {
    echo "error: $1" >&2
    violations=$((violations + 1))
}

if [ ! -d "$WORKFLOWS_DIR" ]; then
    echo "error: $WORKFLOWS_DIR is not a directory" >&2
    exit 1
fi

# One record per calling job: "<caller file>\t<job id>\t<called path>\t<yes|no>",
# the last field saying whether the job has a `secrets:` key. Job ids are the
# two-space-indented keys under `jobs:`; a job's `uses:` and `secrets:` are
# four-space-indented, which is also what keeps a step's `- uses:` (six
# spaces, and never a reusable workflow) from being mistaken for a call.
# Order within the job is not assumed: `secrets:` may precede `uses:`.
callers() { # file
    awk -v file="$1" '
        function flush() {
            if (job != "" && called != "")
                printf "%s\t%s\t%s\t%s\n", file, job, called, (has_secrets ? "yes" : "no")
            job = ""; called = ""; has_secrets = 0
        }
        /^jobs:[[:space:]]*$/ { injobs = 1; next }
        /^[^[:space:]#]/ { flush(); injobs = 0; next }
        injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            flush(); job = $1; sub(/:$/, "", job); next
        }
        injobs && job != "" && /^    uses:[[:space:]]*\.\/\.github\/workflows\// {
            called = $2; sub(/^\.\/\.github\/workflows\//, "", called); next
        }
        injobs && job != "" && /^    secrets:/ { has_secrets = 1; next }
        END { flush() }
    ' "$1"
}

# `while read < <(...)` rather than a pipe: the loop body must be able to
# update `violations` and `checked` in this shell, and a piped loop runs in a
# subshell that discards both (see
# docs/learnings/command-substitution-discards-callee-state.md for the
# family of trap this is).
for caller in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
    [ -e "$caller" ] || continue
    while IFS=$'\t' read -r file job called has_secrets; do
        [ -n "$job" ] || continue
        checked=$((checked + 1))
        callee="$WORKFLOWS_DIR/$called"
        if [ ! -r "$callee" ]; then
            err "$(basename "$file") job '$job' calls $called, which does not exist under $WORKFLOWS_DIR"
            continue
        fi
        # Anchored to the expression opener so a prose mention of "secrets."
        # in a comment does not count; only an actual `${{ secrets.X }}` read
        # does.
        if grep -Eq '\$\{\{[^}]*secrets\.' "$callee" && [ "$has_secrets" = "no" ]; then
            err "$(basename "$file") job '$job' calls $called, which reads \${{ secrets.* }}, but passes it no secrets. A called workflow receives none unless the caller hands them over: add 'secrets: inherit' to the job (an environment declared in the called job still decides which values the names resolve to)"
        fi
    done < <(callers "$caller")
done

if [ "$violations" -ne 0 ]; then
    echo "check-called-workflow-secrets: $violations problem(s)" >&2
    exit 1
fi

echo "check-called-workflow-secrets: ok - $checked reusable-workflow call(s) pass the secrets their callee reads"
