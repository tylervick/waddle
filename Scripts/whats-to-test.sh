#!/bin/bash
# Assembles TestFlight "What to Test" notes and attaches them to a build in
# App Store Connect.
#
# Usage:
#   Scripts/whats-to-test.sh --print            assemble and print (no App
#                                               Store Connect; pull-request
#                                               summaries best-effort)
#   Scripts/whats-to-test.sh <build-number>      assemble and attach via ASC
#
# The notes are an optional hand-written preamble followed by a changelog
# computed from git. The changelog is DERIVED, not stored, and that is the
# point: a tracked notes file goes stale silently -- it is not empty, so an
# empty-check passes, and the build ships the previous release's text. A
# computed changelog cannot be stale. See
# docs/superpowers/specs/2026-08-11-whats-to-test-design.md.
#
# The changelog is written for a TESTER, not a reviewer (issue #93): changes
# are grouped into "In the app" and "Behind the scenes" -- everything stays,
# nothing is filtered -- with the conventional-commit prefix consumed as the
# grouping signal and dropped from the visible text along with PR numbers.
# When a change came through a pull request whose body yields a usable first
# sentence, that plain-language sentence replaces the commit subject; every
# fetch failure falls back to the subject (see pr_fetch/pr_summary). A
# BOT-authored body is exempt and keeps its subject: its opener is generated
# boilerplate, identical across every one of its pull requests, and using it
# gave build 214 six consecutive copies of the same bullet (issue #194; see
# pr_author_is_bot). A merge
# commit whose body is empty recovers its title from the PR, or from the
# merged branch's tip commit, never from git's own "Merge pull request"
# subject (issue #102; see changelog). --print and the attach path share this
# code exactly, so the preview never differs from the payload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREAMBLE_FILE="docs/app-store/whats-to-test.md"

API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
# Overridable so the hermetic suite never really sleeps.
POLL_ATTEMPTS="${WHATS_TO_TEST_POLL_ATTEMPTS:-30}"
POLL_DELAY="${WHATS_TO_TEST_POLL_DELAY:-30}"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"

# App Store Connect caps a build's whatsNew at about 4000 characters and
# rejects an over-long value -- AFTER the upload has consumed a build number
# and the tag has been pushed, which is the most expensive moment to find
# out. At the two or three merged pull requests a day this repo lands, a few
# weeks between releases is enough to overrun it. So the notes are trimmed on
# a whole-bullet boundary below the cap and say how many changes were
# dropped, rather than being sent for Apple to refuse.
NOTES_MAX=3900

# Owner/repo for pull-request lookups, derived from the origin remote rather
# than hard-coded, so the hermetic test fixtures -- throwaway repos with no
# origin remote at all -- never see a reason to touch the network. Anything
# that is not a github.com remote reads as "no slug", which disables the
# fetch entirely; pr_summary then never runs and every bullet keeps its
# commit subject.
repo_slug() {
    local url slug
    url="$(git remote get-url origin 2>/dev/null)" || return 1
    case "$url" in
        git@github.com:*)       slug="${url#git@github.com:}" ;;
        ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
        https://github.com/*)   slug="${url#https://github.com/}" ;;
        http://github.com/*)    slug="${url#http://github.com/}" ;;
        *) return 1 ;;
    esac
    slug="${slug%.git}"
    case "$slug" in
        */*) printf '%s' "$slug" ;;
        *) return 1 ;;
    esac
}

# One GET of a pull request, shared by pr_title and pr_summary below so a
# change never costs two fetches. This is BEST-EFFORT and every failure --
# offline, rate limited (the anonymous limit is easy to hit from a shared CI
# IP), a token without pull-requests: read, a deleted PR -- returns non-zero
# and the caller falls back to what git already gave it. A release must never
# fail, and never stall longer than --max-time, because the API was
# unavailable (issue #93). curl's exit status IS tested, per
# docs/learnings/masked-exit-status-fails-open.md; its stderr is suppressed
# because falling back is the designed answer here, and changelog prints one
# aggregate note instead of per-PR noise. GH_TOKEN/GITHUB_TOKEN is attached
# when present so a runner that grants pull-requests: read authenticates;
# absent, the fetch is anonymous, which works for a public repository
# outside rate-limit windows.
pr_fetch() { # owner/repo, pr-number
    local token
    token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -n "$token" ]; then
        curl -s -f --max-time 10 -H "Authorization: Bearer $token" \
            "https://api.github.com/repos/$1/pulls/$2"
    else
        curl -s -f --max-time 10 \
            "https://api.github.com/repos/$1/pulls/$2"
    fi
}

# The pull request's title, from a pr_fetch response on stdin. This is the
# recovery path for a merge commit whose body carries no title line (issue
# #102): the title field arrives in the same response pr_summary reads, and
# it is the PR title -- exactly the line GitHub would have written into the
# merge body had the merge gone through the other path. Non-zero on any
# parse failure or an empty title, and the caller falls back further.
pr_title() { # reads the pr_fetch response on stdin
    python3 -c '
import json, sys
try:
    doc = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    title = (doc.get("title") or "").strip()
except Exception:
    sys.exit(1)
if not title:
    sys.exit(1)
sys.stdout.buffer.write(title.encode("utf-8"))
'
}

# Whether a pr_fetch response's author is a bot, read from the same response
# the title and the summary ride on. A bot's body is GENERATED text with a
# fixed opener, not a human explaining a change, so pr_summary is skipped for
# one and the commit subject stands instead -- the existing no-summary path.
# Without this every Renovate pull request contributed the identical bullet
# "This PR contains the following updates:", six consecutively in build 214's
# shipped notes (issue #194): its table is correctly skipped, so that
# boilerplate opener IS the first and only prose paragraph, and the 15..240
# guard admits it happily.
#
# Two independent signals, either sufficient: GitHub reports an App's author
# as type "Bot", and spells its login with a "[bot]" suffix that no human
# account can hold (GitHub rejects brackets in usernames). Keying on the
# literal boilerplate sentence instead would be wrong twice over -- Renovate's
# wording is not ours to depend on, and the next bot's differs.
#
# Exit 1 -- "not a bot", the conservative answer -- on any parse failure or
# absent user field, so an unreadable response keeps today's behaviour and
# falls through to pr_summary, which fails on it in turn and lands on the
# subject. stdin is read to completion before any exit: quitting early would
# break printf's pipe and, under pipefail, fail the whole pipeline (see
# docs/learnings/pipefail-with-early-exit-consumer.md).
pr_author_is_bot() { # reads the pr_fetch response on stdin
    python3 -c '
import json, sys
raw = sys.stdin.buffer.read()
try:
    user = json.loads(raw.decode("utf-8")).get("user") or {}
    login = (user.get("login") or "").strip()
    kind = (user.get("type") or "").strip()
except Exception:
    sys.exit(1)
sys.exit(0 if kind == "Bot" or login.endswith("[bot]") else 1)
'
}

# First usable sentence of a pull request's body, from a pr_fetch response on
# stdin. Best-effort decoration: an empty or unusable body returns non-zero
# and the caller keeps the visible text it already has.
pr_summary() { # reads the pr_fetch response on stdin
    python3 -c '
import json, re, sys

# The body arrives as markdown written for reviewers. The first sentence of
# its first prose paragraph is the part that explains the change in plain
# language, so that becomes the bullet: headings, HTML comments (PR
# templates), code fences, list items, quotes, tables and images are
# skipped; emphasis and links are unwrapped. Anything outside 15..240
# characters is rejected -- too short to inform, or long enough to crowd
# the whole notes field -- and the caller falls back to the subject. The
# sentence terminator set is "." and "?" only: this project ships an engine
# literally named "Woof!", so "!" would cut mid-name.
try:
    doc = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    body = doc.get("body") or ""
except Exception:
    sys.exit(1)
body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
para = []
in_code = False
for raw in body.splitlines():
    line = raw.strip()
    if line.startswith("```") or line.startswith("~~~"):
        in_code = not in_code
        continue
    if in_code:
        continue
    if not line or line[0] in "#-*+>|!" or re.match(r"\d+[.)] ", line):
        if para:
            break
        continue
    para.append(line)
text = " ".join(para)
text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
text = re.sub(r"[`*_]", "", text)
text = re.sub(r"\s+", " ", text).strip()
m = re.match(r"(.+?[.?])(\s|$)", text)
sentence = (m.group(1) if m else text).strip()
if not 15 <= len(sentence) <= 240:
    sys.exit(1)
sys.stdout.buffer.write(sentence.encode("utf-8"))
'
}

# One bullet per change, tagged app<TAB>text or other<TAB>text for
# format_groups below. For a GitHub merge commit the useful title is the
# FIRST LINE OF THE BODY -- git's own subject is "Merge pull request #N from
# owner/branch", which tells a tester nothing. Direct commits use their
# subject. Both shapes occur in this repo.
#
# Some merge paths write NO body at all (observed on #100 and #101), and
# whether a bullet reads as a change or as a branch name must not depend on
# how the merge was performed (issue #102). So an empty body recovers a real
# title instead of degrading to git's subject: the pull request's title when
# the API is reachable -- the same response the prose summary rides on -- and
# otherwise the merged branch's tip commit subject (the merge's second
# parent). The tip subject is local and free, it IS the PR title for the
# single-commit branches this repo's flow produces, and it is a conventional
# commit, so the grouping below still reads a real prefix instead of
# defaulting a docs merge into the app section. Grouping runs on the
# recovered title, never on "Merge pull request #N ...".
#
# The conventional-commit prefix is CONSUMED here, never shown: its type and
# scope decide the group, and the visible text is the subject with the
# prefix and any trailing "(#N)" dropped -- both are this repo's
# conventions, not a tester's vocabulary, and the PR numbers point at a
# repository most testers cannot see (issue #93).
changelog() { # range (may be empty, meaning "recent history")
    range="$1"
    FETCH_TRIED=0
    FETCH_FALLBACK=0
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        subj="$(git log -1 --format=%s "$sha")"
        num=""
        resp=""
        fetch_done=0
        case "$subj" in
            "Merge pull request #"*)
                num="$(printf '%s' "$subj" | sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p')"
                title="$(git log -1 --format=%b "$sha" | sed -n '1p')"
                if [ -z "$title" ] && [ -n "$num" ] && [ -n "$REPO_SLUG" ]; then
                    # Empty body: recover the title from the PR itself. The
                    # response is kept for the summary step below, so the
                    # recovery never costs a second fetch.
                    fetch_done=1
                    resp="$(pr_fetch "$REPO_SLUG" "$num")" || resp=""
                    if [ -n "$resp" ]; then
                        title="$(printf '%s' "$resp" | pr_title)" || title=""
                    fi
                fi
                if [ -z "$title" ]; then
                    # Unreachable API (or no slug at all): the merged
                    # branch's tip commit subject, never the merge subject.
                    title="$(git log -1 --format=%s "$sha^2" 2>/dev/null)" || title=""
                fi
                [ -n "$title" ] || title="$subj"
                ;;
            *) title="$subj" ;;
        esac

        # A squash-merge subject carries its PR number as a trailing " (#N)".
        # Consume it for the summary fetch and drop it from the visible text.
        case "$title" in
            *" (#"*")")
                tail_num="${title##* (#}"; tail_num="${tail_num%)}"
                case "$tail_num" in
                    ''|*[!0-9]*) ;;
                    *)
                        [ -n "$num" ] || num="$tail_num"
                        title="${title% (#*}"
                        ;;
                esac
                ;;
        esac

        # Prefix -> group. Types that cannot change what a tester is holding
        # go behind the scenes outright; behaviour-changing types (fix, feat,
        # perf -- plus this repo's occasional bare "engine:" / "app:") stay
        # in the app group UNLESS the scope names tooling or process.
        # Anything unparseable defaults to the app group: a stray tooling
        # note at the top costs a tester one glance, but an app change buried
        # under tooling is exactly the failure issue #93 exists to fix.
        ctype="$(printf '%s' "$title" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p')"
        cscope="$(printf '%s' "$title" | sed -nE 's/^[a-z]+\(([^)]*)\)!?: .*/\1/p')"
        text="$title"
        if [ -n "$ctype" ]; then
            text="$(printf '%s' "$title" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //')"
        fi
        group="app"
        case "$ctype" in
            docs|test|chore|ci|build|refactor|style|rename|deps|revert) group="other" ;;
            *)
                case "$cscope" in
                    loop|loop-report|loop-trials|agent-loop|release|ci|scripts|docs|learnings|app-store|substrate|spec|specs|plan|plans|build|signing|deps|repo|readme|workflow) group="other" ;;
                esac
                ;;
        esac

        if [ -n "$num" ] && [ -n "$REPO_SLUG" ]; then
            FETCH_TRIED=$((FETCH_TRIED + 1))
            if [ "$fetch_done" -eq 0 ]; then
                resp="$(pr_fetch "$REPO_SLUG" "$num")" || resp=""
            fi
            if [ -n "$resp" ] && printf '%s' "$resp" | pr_author_is_bot; then
                # A bot: keep the subject, which names the actual dependency.
                # NOT counted as a fallback -- the fetch succeeded and the
                # summary was declined, so the stderr note below would
                # otherwise report an API problem that never happened.
                :
            elif [ -n "$resp" ] && summary="$(printf '%s' "$resp" | pr_summary)" && [ -n "$summary" ]; then
                text="$summary"
            else
                FETCH_FALLBACK=$((FETCH_FALLBACK + 1))
            fi
        fi
        printf '%s\t%s\n' "$group" "$text"
    done < <(git log --first-parent --format=%H $range)
    if [ "$FETCH_FALLBACK" -gt 0 ]; then
        echo "note: pull request summaries unavailable for $FETCH_FALLBACK of $FETCH_TRIED changes; using their commit subjects." >&2
    fi
}

# Folds changelog's group-tagged lines into the two tester-facing sections.
# "In the app" leads because finding the part that concerns a tester at a
# glance is the point (issue #93); everything else still appears, under
# "Behind the scenes", so the whole picture of what moved stays visible.
# When nothing app-facing changed, that is stated outright rather than
# implied by an absent section -- "nothing to retest" is itself the most
# useful fact the notes can carry that week. python3 (already a dependency)
# for the same surrogateescape reason as trim_notes: a commit subject can
# carry any byte and must round-trip exactly.
format_groups() {
    python3 -c '
import sys

app, other = [], []
data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
for line in data.splitlines():
    group, sep, text = line.partition("\t")
    text = text.strip()
    if not sep or not text:
        continue
    text = text[0].upper() + text[1:]
    (app if group == "app" else other).append("- " + text)
sections = []
if app:
    sections.append("In the app:\n" + "\n".join(app))
elif other:
    sections.append("Nothing in the app itself changed in this build.")
if other:
    sections.append("Behind the scenes:\n" + "\n".join(other))
sys.stdout.buffer.write("\n\n".join(sections).encode("utf-8", "surrogateescape"))
'
}

# Picks the tag that anchors the changelog range: the newest `build-*` tag
# STRICTLY BELOW the build being annotated, or -- when no build number is
# given, i.e. `--print` -- the newest one there is.
#
# "Strictly below" is the whole feature, not a refinement. The workflow pushes
# `build-<N>` at HEAD in the step immediately BEFORE the one that attaches the
# notes, and that ordering is load-bearing and stays (the tag records what
# shipped; gating it on notes would corrupt the NEXT release's anchor -- see
# the spec). So at the moment the notes are assembled, the newest tag IS the
# build being annotated and it sits on HEAD: anchoring on it makes the range
# `build-N..HEAD`, which is empty on EVERY release. With no preamble that goes
# red after a successful upload; with a preamble it goes GREEN and ships the
# preamble alone with the changelog silently gone -- the confidently-wrong
# outcome the derived changelog exists to prevent.
#
# TAG_LIST arrives sorted -v:refname, highest first, so the first entry below
# the current number is the anchor. Version order, not tag date: build numbers
# skip when a validate-only run consumes a run number, so lexical or
# chronological ordering would both pick the wrong anchor.
prev_tag() { # [current-build-number]
    printf '%s\n' "$TAG_LIST" | awk -v n="${1:-}" '
        { num = $0; sub(/^build-/, "", num) }
        (n == "" || num + 0 < n + 0) { print; exit }'
}

# Assembles the preamble + derived changelog and prints the result to stdout.
# Shared by --print (called directly, so its output goes straight to the
# terminal) and the attach path below (captured via
# `NOTES="$(assemble_notes "$BUILD")"` to build a request body).
# assemble_notes has no side effects beyond writing stdout and its own exit
# status, so capturing it this way is safe -- see
# docs/learnings/command-substitution-discards-callee-state.md for the
# failure mode this would otherwise risk (it applies to functions that need
# their global writes or their `exit` to reach the caller; this one needs
# neither).
assemble_notes() { # [current-build-number]
    PREAMBLE=""
    if [ -f "$PREAMBLE_FILE" ]; then
        PREAMBLE="$(sed -e 's/[[:space:]]*$//' "$PREAMBLE_FILE" | sed -e '/./,$!d')"
    fi

    # The list command's status is tested directly rather than masked with
    # `2>/dev/null` and read as data: a genuine `git tag` failure (corrupt
    # refs, a shallow or partial checkout) produces the same empty output as
    # "no build tag yet", so masking it would silently route a broken
    # repository into the once-ever bootstrap fallback below and compute the
    # changelog from the last 20 commits instead of the true range -- without
    # saying anything is wrong. See
    # docs/learnings/masked-exit-status-fails-open.md. A real failure here is
    # not the bootstrap condition the fallback exists for, so it fails the
    # run rather than falling back. (Under `set -e` an unguarded assignment
    # from a failing `git tag` would abort the script with a bare exit 128 and
    # no diagnostic of our own -- it would NOT reach the fallback -- so this
    # guard is what turns that silent death into a named failure, not what
    # prevents a wrong fallback.)
    #
    # git's stderr goes to a FILE, never folded into the captured stdout with
    # `2>&1`: git writes advisories to stderr while still exiting 0 (`warning:
    # ignoring broken ref refs/tags/...` and friends), and with `2>&1` such a
    # line becomes the first entry of TAG_LIST and therefore the anchor. The
    # range is then `warning: ....HEAD`, `git log` fails inside changelog's
    # process substitution -- which does NOT trip `set -e` -- and BODY comes
    # back empty. With a preamble present that ships green with the changelog
    # silently gone: the same confidently-wrong outcome as a bad anchor.
    TAG_ERR="$(mktemp "${TMPDIR:-/tmp}/whats-to-test-tag.XXXXXX")"
    if ! TAG_LIST="$(git tag --list 'build-*' --sort=-v:refname 2>"$TAG_ERR")"; then
        echo "error: git tag --list failed; cannot determine the previous build tag." >&2
        cat "$TAG_ERR" >&2
        rm -f "$TAG_ERR"
        exit 1
    fi
    rm -f "$TAG_ERR"
    TAG="$(prev_tag "${1:-}")"

    # Resolved once per assembly. Empty means "no pull-request fetches at
    # all" -- no origin remote (every hermetic fixture), or not GitHub.
    REPO_SLUG="$(repo_slug)" || REPO_SLUG=""

    # The heading keeps the build number on purpose (issue #93 left it open):
    # TestFlight shows the number on the build a tester is holding and on the
    # previous one, so it is the one piece of bookkeeping a tester can
    # actually cross-reference, and it anchors "worked in 207" bug reports.
    if [ -n "$TAG" ]; then
        HEADING="Changes since build ${TAG#build-}:"
        BODY="$(changelog "$TAG..HEAD" | format_groups)"
    else
        # Bootstrap: no release below this one has ever been tagged -- either
        # no build-* tag exists at all, or the only one is the tag this very
        # release just pushed. Failing here would block a release for a
        # condition that is true exactly once, so fall back -- but disclose
        # it, because the range is a guess rather than a fact.
        HEADING="Recent changes (no previous build tag; showing the last 20 commits):"
        BODY="$(changelog "--max-count=20" | format_groups)"
    fi

    if [ -z "$PREAMBLE" ] && [ -z "$BODY" ]; then
        echo "error: no changes since ${TAG:-the start of history} and $PREAMBLE_FILE is empty." >&2
        echo "       Nothing to tell a tester. Write a preamble or ship a build with changes in it." >&2
        exit 1
    fi

    OUT=""
    if [ -n "$PREAMBLE" ]; then
        OUT="$PREAMBLE"
        # A blank line between the preamble and the changelog.
        if [ -n "$BODY" ]; then OUT="$OUT"$'\n\n'; fi
    fi
    if [ -n "$BODY" ]; then
        OUT="$OUT$HEADING"$'\n\n'"$BODY"
    fi
    # Trimmed HERE rather than at the request body, so `--print` shows exactly
    # what will be sent -- a preview that silently differs from the payload is
    # the same class of lie as stale notes.
    trim_notes "$OUT"
    printf '\n'
}

# Keeps the notes under App Store Connect's whatsNew cap (see NOTES_MAX),
# dropping WHOLE bullets from the end -- a body cut mid-line reads as
# corruption, while "and N more changes" is a fact a tester can act on. Done
# in python3 (already a dependency, see json_first) because the cap is in
# characters and `${#var}` counts bytes under a C locale: counting bytes would
# trim more aggressively than needed, and counting characters is what Apple
# does.
trim_notes() { # text
    TRIM_TEXT="$1" TRIM_MAX="$NOTES_MAX" python3 -c '
import os, sys

# Written as UTF-8 BYTES rather than through sys.stdout: a commit subject can
# carry any byte, os.environ decoded it with surrogateescape, and re-encoding
# the same way round-trips it exactly. Going through sys.stdout would instead
# raise UnicodeEncodeError under a non-UTF-8 locale -- aborting the release
# over a name with an accent in it, after the upload.
def emit(s):
    sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape"))

text = os.environ["TRIM_TEXT"]
limit = int(os.environ["TRIM_MAX"])
if len(text) <= limit:
    emit(text)
    raise SystemExit(0)

def tail(n):
    return "\n… and %d more change%s" % (n, "" if n == 1 else "s")

lines = text.split("\n")
dropped = 0
while len(lines) > 1 and len("\n".join(lines)) + len(tail(dropped + 1)) > limit:
    # Only a bullet is a dropped CHANGE: the body carries group headings and
    # blank lines too, and counting those would inflate "and N more changes".
    if lines.pop().startswith("- "):
        dropped += 1
if dropped:
    # Trimming can leave a section heading or a blank line dangling at the
    # cut; sweep those so the tail never follows a heading with no bullets.
    while len(lines) > 1 and not lines[-1].startswith("- "):
        lines.pop()
out = "\n".join(lines) + (tail(dropped) if dropped else "")
# A preamble that is itself over the cap cannot be fixed by dropping bullets.
# Clamp it rather than let App Store Connect reject the whole write after the
# upload and the tag have already happened.
emit(out[:limit])
'
}

# Extracts a top-level JSON string field from the first element of `data`.
# python3 stdlib rather than jq: jq is not guaranteed on a runner and this
# script must add no dependencies.
json_first() { # field-path e.g. "id" or "attributes.processingState"
    python3 -c '
import json, sys
doc = json.load(sys.stdin)
items = doc.get("data") or []
if not items:
    sys.exit(3)
cur = items[0]
for part in sys.argv[1].split("."):
    cur = (cur or {}).get(part)
print(cur if cur is not None else "")
' "$1"
}

api_get() { # path
    # Status tested directly, never masked: a failed call must not read as an
    # empty result. See docs/learnings/masked-exit-status-fails-open.md.
    curl -sS -f -H "Authorization: Bearer $TOKEN" "$API$1"
}

# Reads one field from a JSON response that has already been confirmed to
# come from a successful call (i.e. the caller tested api_get's own status
# first -- see api_get above). This function's only remaining job is to
# distinguish json_first's own exit 3, "data is empty" -- the ONE legitimate
# reading of "nothing here yet" -- from any other non-zero exit (malformed
# JSON, an unexpected shape), which is a parse failure and must abort rather
# than be folded into that same "empty" reading. Folding the two together is
# exactly how a failed request reads as a successful empty one: see
# docs/learnings/masked-exit-status-fails-open.md. Prints the field's value
# and returns 0 on success, prints nothing and returns 3 on "no items",
# prints nothing and returns 1 on anything else.
read_json_field() { # response, field-path
    local val rc
    # rc is captured in an explicit `else`, not by reading $? after a
    # bodyless `if`: with no `else` clause, POSIX defines a not-taken `if`'s
    # own exit status as 0 regardless of the condition's real status, which
    # would silently turn every failure here into a false "success".
    #
    # json_first's own stderr (a raw python traceback on malformed input) is
    # discarded, not its exit status -- every caller of this function prints
    # its own purpose-built diagnostic immediately on a non-3 return, so the
    # traceback would only ever precede and obscure that message, never
    # replace the failure signal itself.
    if val="$(printf '%s' "$1" | json_first "$2" 2>/dev/null)"; then
        printf '%s' "$val"
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 3 ] && return 3
    return 1
}

# POSTs or PATCHes. `--fail-with-body` (not bare `-f`) so a non-2xx still
# writes Apple's error body -- which explains *why* the write failed (a
# validation error, a conflicting locale, ...) -- rather than throwing that
# reason away and leaving the operator with only "it failed". The body is
# captured rather than streamed straight out, specifically so it can be
# withheld on success (never useful there) and shown only on failure. The
# request body travels over stdin (`--data-binary @-`) rather than as a
# command-line argument, so arbitrarily long or oddly-shaped JSON is never
# reinterpreted by the shell.
api_send() { # method, path, json-body
    local resp
    if resp="$(curl -sS --fail-with-body -X "$1" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            "$API$2" <<< "$3")"; then
        return 0
    fi
    printf '%s\n' "$resp" >&2
    return 1
}

# Builds the JSON body for creating (no loc-id) or updating (loc-id given) the
# en-US beta build localization. Built with python3's json.dumps rather than
# shell string interpolation: NOTES is release-notes text that can contain
# newlines, quotes, and backslashes verbatim, and passing it through
# json.dumps is what guarantees both that those characters survive intact and
# that the result is syntactically valid JSON -- a naive `"whatsNew": "$NOTES"`
# would corrupt on the first embedded quote or literal newline. Values cross
# into python via the environment (not as `-c` script text) for the same
# reason asc-jwt.sh escapes its claims: nothing here is interpolated into code
# python parses.
loc_body() { # build-id, notes, [loc-id]
    LOC_BUILD_ID="$1" LOC_NOTES="$2" LOC_LOC_ID="${3:-}" python3 -c '
import json, os
build_id = os.environ["LOC_BUILD_ID"]
notes = os.environ["LOC_NOTES"]
loc_id = os.environ.get("LOC_LOC_ID") or None
data = {"type": "betaBuildLocalizations", "attributes": {"whatsNew": notes}}
if loc_id:
    data["id"] = loc_id
else:
    data["attributes"]["locale"] = "en-US"
    data["relationships"] = {"build": {"data": {"type": "builds", "id": build_id}}}
print(json.dumps({"data": data}))
'
}

MODE="${1:---print}"

if [ "$MODE" = "--print" ]; then
    assemble_notes
    exit 0
fi

BUILD="$MODE"
case "$BUILD" in ''|*[!0-9]*) echo "usage: $0 --print | <build-number>" >&2; exit 2 ;; esac

# The build number is passed in so the changelog anchors on the newest tag
# BELOW it: build-$BUILD already exists at HEAD by the time this runs (the
# workflow tags before attaching notes), so anchoring on the newest tag
# overall would make every range empty. See prev_tag.
NOTES="$(assemble_notes "$BUILD")" \
  || { echo "error: could not assemble What-to-Test notes for build $BUILD" >&2; exit 1; }
TOKEN="$("$ASC_JWT")" \
  || { echo "error: could not mint an App Store Connect API token for build $BUILD" >&2; exit 1; }
# Cheap insurance on a public repo: the token is never printed by this script,
# but a stray `set -x`, a future `curl -v`, or a diagnostic added in haste
# would put it in the log. Registering it means GitHub redacts it from every
# subsequent line of this job. Guarded on GITHUB_ACTIONS so a local run does
# not print a stray workflow command.
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi

# Two curl calls, not one piped into json_first, so a failed lookup is
# diagnosed by our own clean message rather than by a python traceback from
# json_first choking on the empty stdin a failed `-f` call leaves behind
# (curl's status is tested and handled before json_first ever runs).
APPS_RESP="$(api_get "/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID")" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID (build $BUILD)" >&2; exit 1; }
# read_json_field, not a bare json_first: "the API returned no app for this
# bundle id" (its exit 3) is a different fact from "the response could not be
# parsed", and they have different fixes -- a wrong bundle id or an API key
# without access to the app, versus a broken response. Reporting the first as
# the second sends the operator looking in the wrong place.
if APP_ID="$(read_json_field "$APPS_RESP" id)"; then
    :
else
    rc=$?
    if [ "$rc" -eq 3 ]; then
        echo "error: App Store Connect has no app matching bundle id $BUNDLE_ID (build $BUILD)." >&2
        echo "       Check the bundle id and that the API key has access to the app." >&2
    else
        echo "error: could not parse App Store Connect's response resolving the app id for $BUNDLE_ID (build $BUILD)" >&2
    fi
    exit 1
fi

# Poll until the build is ADDRESSABLE, which is two conditions and not one.
#
# `data: []` -- no such build -- is the NORMAL answer for the first minute or
# more after altool returns: App Store Connect creates the build resource when
# ingestion begins, not when the upload completes. Treating an absent build as
# an immediate failure fails a release that is merely early, at the one moment
# retrying costs a whole build number. So an absent build is polled for, and
# only running out of attempts is a failure. Once it does appear it then sits
# in PROCESSING for minutes more (several, for build 205), so both conditions
# have to clear before the localization write can land.
#
# STATE and BUILD_ID are both initialized before the loop: with `set -u`, a
# WHATS_TO_TEST_POLL_ATTEMPTS of 0 or a negative/non-numeric override means
# the loop body below never runs even once, and either variable being
# referenced afterward while still unset would abort with a bare "unbound
# variable" -- naming neither the build nor what went wrong.
STATE=""
BUILD_ID=""
attempt=0
while [ "$attempt" -lt "$POLL_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    RESP="$(api_get "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD")" \
      || { echo "error: could not query App Store Connect for build $BUILD" >&2; exit 1; }

    if BUILD_ID="$(read_json_field "$RESP" id)"; then
        :
    else
        rc=$?
        [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's response while polling build $BUILD" >&2; exit 1; }
    fi
    if STATE="$(read_json_field "$RESP" attributes.processingState)"; then
        :
    else
        rc=$?
        [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's response while polling build $BUILD" >&2; exit 1; }
    fi

    if [ -n "$BUILD_ID" ] && [ "$STATE" != "PROCESSING" ]; then break; fi
    if [ "$attempt" -lt "$POLL_ATTEMPTS" ]; then sleep "$POLL_DELAY"; fi
done
if [ "$attempt" -eq 0 ]; then
    echo "error: build $BUILD was never polled -- WHATS_TO_TEST_POLL_ATTEMPTS must be at least 1." >&2
    exit 1
fi
if [ -z "$BUILD_ID" ]; then
    echo "error: build $BUILD never appeared in App Store Connect after $attempt attempts; notes not attached." >&2
    echo "       Either it is still being ingested, or nothing was uploaded under that build number." >&2
    exit 1
fi
if [ "$STATE" = "PROCESSING" ]; then
    echo "error: build $BUILD is still PROCESSING after $POLL_ATTEMPTS attempts; notes not attached." >&2
    exit 1
fi

# Find an existing en-US localization for this build. Filtered server-side by
# both build and locale, so at most one result is possible and `data: []`
# unambiguously means "none exists yet" -- once the call itself is confirmed
# to have succeeded. That confirmation happens above, on api_get's own exit
# status via `||`, before LOC_RESP is ever treated as data: a failed call
# aborts right here and never reaches the "is it empty" question at all, so
# "no existing localization" and "the request failed" cannot be confused with
# each other. Nor can a malformed-but-200 body: read_json_field's own
# distinction between exit 3 ("no items", benign) and anything else (a parse
# failure) means a garbled response can't be misread as "no localization
# yet" either. See docs/learnings/masked-exit-status-fails-open.md.
LOC_RESP="$(api_get "/v1/betaBuildLocalizations?filter%5Bbuild%5D=$BUILD_ID&filter%5Blocale%5D=en-US")" \
  || { echo "error: could not look up beta build localizations for build $BUILD" >&2; exit 1; }
if LOC_ID="$(read_json_field "$LOC_RESP" id)"; then
    :
else
    rc=$?
    [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's beta build localization response for build $BUILD" >&2; exit 1; }
fi

BODY="$(loc_body "$BUILD_ID" "$NOTES" "$LOC_ID")" \
  || { echo "error: could not build the request body for build $BUILD" >&2; exit 1; }
if [ -n "$LOC_ID" ]; then
    api_send PATCH "/v1/betaBuildLocalizations/$LOC_ID" "$BODY" \
      || { echo "error: failed to update the What-to-Test localization for build $BUILD" >&2; exit 1; }
else
    api_send POST "/v1/betaBuildLocalizations" "$BODY" \
      || { echo "error: failed to create the What-to-Test localization for build $BUILD" >&2; exit 1; }
fi

echo "Attached What-to-Test notes to build $BUILD."
