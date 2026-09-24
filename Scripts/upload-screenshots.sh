#!/bin/bash
# Replaces the App Store screenshots of one app version with the committed
# docs/app-store/screenshots/<device>/ sets, through the App Store Connect API.
#
# Dry run by default: it resolves everything, checks every local file, and
# prints what it would do. Nothing on App Store Connect changes without
# --apply. The 1.0 and 1.1 sets were swapped by hand; each of the traps below
# was paid for once on the way, and this script exists so they are not paid
# again (docs/app-store/metadata.md §12):
#
#   * An appScreenshotSet holds at most 10, so a 6-for-6 swap fails the fifth
#     upload with 409 STATE_ERROR.SCREENSHOT_TOO_MANY unless the old six are
#     deleted FIRST. That inverts the usual commit-then-delete order, and is
#     safe only because an editable version's sets are copies, distinct ids
#     from a released version's. This script checks that distinction against
#     the API before it deletes anything -- it does not trust it.
#   * `sips --rotate` once left an EXIF Orientation tag in a PNG; App Store
#     Connect honoured it, stored the shot sideways and reported
#     assetDeliveryState COMPLETE regardless. Local files carrying an eXIf
#     chunk are refused, and every upload is verified twice: its reported
#     dimensions must not be transposed, and a rendition fetched back from its
#     templateUrl must be landscape.
#
# Usage:
#   Scripts/upload-screenshots.sh [--apply] [--version X.Y] [--device iphone|ipad|all]
#
# Env:
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   for Scripts/asc-jwt.sh
#   ASC_JWT           override the JWT minter (tests use this)
#   ASC_APP_ID        override the App Store Connect app id
#   SCREENSHOTS_DIR   override docs/app-store/screenshots (tests use this)
#   UPLOAD_POLL_ATTEMPTS / UPLOAD_POLL_DELAY   delivery polling (tests set 0 delay)
#
# A failure after deleting leaves that version's set partly filled. It is not
# live -- the version is editable by the time this runs -- and re-running
# converges, because every run starts by emptying the set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SHOTS_DIR="${SCREENSHOTS_DIR:-$ROOT/docs/app-store/screenshots}"
POLL_ATTEMPTS="${UPLOAD_POLL_ATTEMPTS:-60}"
POLL_DELAY="${UPLOAD_POLL_DELAY:-5}"

# Every numeric knob feeds a `[ -le ]`/`-lt` comparison or `sleep`. A
# non-integer there makes the test error instead of answering, and an erroring
# bound is a loop that never stops -- so refuse it before any network call.
# (API_RETRIES and API_RETRY_MAX_SLEEP are checked the same way in asc-api.sh.)
for knob in "UPLOAD_POLL_ATTEMPTS=$POLL_ATTEMPTS" "UPLOAD_POLL_DELAY=$POLL_DELAY"; do
    case "${knob#*=}" in
        ''|*[!0-9]*) echo "error: ${knob%%=*} must be a non-negative integer, got '${knob#*=}'" >&2; exit 2 ;;
    esac
done
[ "$POLL_ATTEMPTS" -ge 1 ] || { echo "error: UPLOAD_POLL_ATTEMPTS must be at least 1" >&2; exit 2; }

# Slot order, pinned in metadata.md §12. Filenames are upload identifiers that
# describe the slot they first held, not the screen they show now.
SLOTS="05-ingame 01-play-tab 02-library 03-preset-editor 06-automap 04-control-feel"

usage() { echo "usage: $0 [--apply] [--version X.Y] [--device iphone|ipad|all]" >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

APPLY=0; VERSION=""; DEVICE="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --version) VERSION="${2:-}"; [ -n "$VERSION" ] || usage; shift ;;
        --device) DEVICE="${2:-}"; shift ;;
        *) usage ;;
    esac
    shift
done
case "$DEVICE" in iphone) DEVICES="iphone" ;; ipad) DEVICES="ipad" ;; all) DEVICES="iphone ipad" ;; *) usage ;; esac

if [ -z "$VERSION" ]; then
    VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' "$ROOT/App/project.yml" | head -1)"
    [ -n "$VERSION" ] || die "no --version given and no MARKETING_VERSION in App/project.yml"
fi
# The version string is spliced into the JSON filters below, so hold it to the
# shape App Store Connect uses before it goes anywhere near them.
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "not a version number: $VERSION"
export VERSION

# Per device: committed directory, required pixel size (landscape), and the
# App Store Connect display type the slot is uploaded as.
device_dir()  { [ "$1" = iphone ] && echo "iphone-6.9" || echo "ipad-13"; }
device_size() { [ "$1" = iphone ] && echo "2868 1320" || echo "2752 2064"; }
device_type() { [ "$1" = iphone ] && echo "APP_IPHONE_67" || echo "APP_IPAD_PRO_3GEN_129"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=Scripts/asc-api.sh
. "$ROOT/Scripts/asc-api.sh"

# ---- local checks: every file, before any network call --------------------

# Prints "width height has_exif" for a PNG, or fails for anything else.
png_info() { # path
    python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
w, h = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
exif, i = 0, 8
while i < len(data):
    n = int.from_bytes(data[i:i + 4], "big"); kind = data[i + 4:i + 8]
    if kind == b"eXIf": exif = 1
    if kind == b"IEND": break
    i += 12 + n
print(w, h, exif)
PY
}

for dev in $DEVICES; do
    read -r want_w want_h <<EOF
$(device_size "$dev")
EOF
    for slot in $SLOTS; do
        f="$SHOTS_DIR/$(device_dir "$dev")/$slot.png"
        [ -f "$f" ] || die "missing $f"
        info="$(png_info "$f")" || die "$f is not a readable PNG"
        read -r w h exif <<EOF
$info
EOF
        [ "$exif" = 0 ] || die "$f carries an eXIf chunk -- App Store Connect would rotate it (metadata.md §12)"
        [ "$w $h" = "$want_w $want_h" ] || die "$f is ${w}x${h}, expected ${want_w}x${want_h}"
    done
done
echo "ok - local files: $(echo $DEVICES | wc -w | tr -d ' ') device set(s) x 6, sizes and orientation checked"

# ---- API ------------------------------------------------------------------

asc_token

# 1. The version, and whether it can be edited at all.
asc_resolve_editable_version screenshots

# The en-US screenshot sets of a version, as "set-id display-type" lines.
sets_of() { # version-id
    local r loc
    loc="$(asc_localization_id "$1")" || return 1
    [ -n "$loc" ] || return 0
    r="$(api GET "$API/v1/appStoreVersionLocalizations/$loc/appScreenshotSets?limit=50")" || return 1
    printf '%s' "$r" | json "[f'{s[\"id\"]} {s[\"attributes\"][\"screenshotDisplayType\"]}' for s in d['data']]"
}

sets_of "$VERSION_ID" > "$WORK/target-sets" || die "could not list version $VERSION's screenshot sets"

# 2. Every set on a version that is NOT editable -- the live listing and
# anything in review -- is off limits. Collect their ids once.
: > "$WORK/protected-sets"
json "[f'{v[\"id\"]} {v[\"attributes\"].get(\"appVersionState\") or v[\"attributes\"].get(\"appStoreState\")}' for v in d['data'] if v['id'] != env['VERSION_ID']]" \
    < "$WORK/versions.json" > "$WORK/other-versions" || die "could not read the version list"
while read -r vid vstate; do
    [ -n "$vid" ] || continue
    case "$EDITABLE_STATES" in *" $vstate "*) continue ;; esac
    sets_of "$vid" >> "$WORK/protected-sets" || die "could not list the sets of version $vid ($vstate)"
done < "$WORK/other-versions"

# 3. Per device: resolve the target set and prove it is not a protected one.
for dev in $DEVICES; do
    type="$(device_type "$dev")"
    set_id="$(awk -v t="$type" '$2 == t { print $1; exit }' "$WORK/target-sets")"
    if [ -z "$set_id" ]; then
        echo "error: version $VERSION has no $type screenshot set for $dev. It has:" >&2
        sed 's/^/  /' "$WORK/target-sets" >&2
        exit 1
    fi
    if awk -v s="$set_id" '$1 == s { found = 1 } END { exit !found }' "$WORK/protected-sets"; then
        die "set $set_id ($type) also belongs to a non-editable version -- refusing to touch it"
    fi
    resp="$(api GET "$API/v1/appScreenshotSets/$set_id/appScreenshots?limit=50")" \
        || die "could not list the screenshots in set $set_id"
    printf '%s' "$resp" | json "[s['id'] for s in d['data']]" > "$WORK/old-$dev" \
        || die "could not read set $set_id's screenshots"
    echo "$set_id" > "$WORK/set-$dev"
    echo "ok - $dev: set $set_id ($type) holds $(grep -c . "$WORK/old-$dev" || true) screenshot(s), none shared with a live version"
done

if [ "$APPLY" = 0 ]; then
    echo "dry run: would replace them with $SHOTS_DIR/<device>/{$(echo $SLOTS | tr ' ' ',')}.png in that order."
    echo "Re-run with --apply to upload."
    exit 0
fi

# ---- apply ----------------------------------------------------------------

# The rendition check: fetch the stored image at a bounding box and confirm it
# came back landscape. Reported width/height alone missed the sideways store.
check_rendition() { # screenshot-json-file, label
    local tmpl url info
    tmpl="$(json "d['data']['attributes']['imageAsset']['templateUrl']" < "$1")" \
        || { echo "error: $2 has no imageAsset.templateUrl" >&2; return 1; }
    url="$(printf '%s' "$tmpl" | sed -e 's/{w}/400/' -e 's/{h}/400/' -e 's/{f}/png/')"
    curl -sS -f --connect-timeout 10 --max-time 120 -o "$WORK/rendition.png" "$url" \
        || { echo "error: could not fetch $2's rendition" >&2; return 1; }
    info="$(png_info "$WORK/rendition.png")" || { echo "error: $2's rendition is not a PNG" >&2; return 1; }
    read -r rw rh _ <<EOF
$info
EOF
    [ "$rw" -gt "$rh" ] || { echo "error: $2 renders ${rw}x${rh} -- stored sideways" >&2; return 1; }
}

for dev in $DEVICES; do
    set_id="$(cat "$WORK/set-$dev")"
    read -r want_w want_h <<EOF
$(device_size "$dev")
EOF

    # Delete first: the set's cap of 10 leaves no room for six new beside six old.
    while read -r old; do
        [ -n "$old" ] || continue
        api DELETE "$API/v1/appScreenshots/$old" > /dev/null || die "could not delete screenshot $old"
        echo "deleted $dev screenshot $old"
    done < "$WORK/old-$dev"

    : > "$WORK/new-$dev"
    for slot in $SLOTS; do
        f="$SHOTS_DIR/$(device_dir "$dev")/$slot.png"
        size="$(wc -c < "$f" | tr -d ' ')"
        body="{\"data\":{\"type\":\"appScreenshots\",\"attributes\":{\"fileName\":\"$slot.png\",\"fileSize\":$size},\"relationships\":{\"appScreenshotSet\":{\"data\":{\"type\":\"appScreenshotSets\",\"id\":\"$set_id\"}}}}}"
        api POST "$API/v1/appScreenshots" "$body" > "$WORK/reserved.json" || die "could not reserve $dev/$slot"
        shot_id="$(json "d['data']['id']" < "$WORK/reserved.json")" || die "no id in the reservation for $dev/$slot"

        # Upload each part exactly as Apple's uploadOperations describe it.
        json "[f'{o[\"method\"]}\t{o[\"url\"]}\t{o[\"offset\"]}\t{o[\"length\"]}\t' + '\x1f'.join(h['name'] + ': ' + h['value'] for h in (o.get('requestHeaders') or [])) for o in d['data']['attributes']['uploadOperations']]" \
            < "$WORK/reserved.json" > "$WORK/ops" || die "no uploadOperations for $dev/$slot"
        [ -s "$WORK/ops" ] || die "no uploadOperations for $dev/$slot"
        while IFS="$(printf '\t')" read -r method url offset length headers; do
            python3 -c 'import sys; f=open(sys.argv[1],"rb"); f.seek(int(sys.argv[2])); sys.stdout.buffer.write(f.read(int(sys.argv[3])))' \
                "$f" "$offset" "$length" > "$WORK/part"
            set -- -sS -f --connect-timeout 10 --max-time 300 -X "$method" --data-binary "@$WORK/part" -o /dev/null
            if [ -n "$headers" ]; then
                old_ifs="$IFS"; IFS="$(printf '\037')"
                for h in $headers; do set -- "$@" -H "$h"; done
                IFS="$old_ifs"
            fi
            curl "$@" "$url" || die "upload of $dev/$slot failed at offset $offset"
        done < "$WORK/ops"

        checksum="$(python3 -c 'import hashlib,sys; print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$f")"
        api PATCH "$API/v1/appScreenshots/$shot_id" \
            "{\"data\":{\"type\":\"appScreenshots\",\"id\":\"$shot_id\",\"attributes\":{\"uploaded\":true,\"sourceFileChecksum\":\"$checksum\"}}}" \
            > /dev/null || die "could not commit $dev/$slot"

        # Wait for Apple to process it, then verify it is the right way up.
        n=0; state=""
        while :; do
            api GET "$API/v1/appScreenshots/$shot_id" > "$WORK/shot.json" || die "could not read back $dev/$slot"
            state="$(json "(d['data']['attributes'].get('assetDeliveryState') or {}).get('state', '')" < "$WORK/shot.json")" \
                || die "unreadable delivery state for $dev/$slot"
            case "$state" in COMPLETE|FAILED) break ;; esac
            n=$((n + 1))
            [ "$n" -lt "$POLL_ATTEMPTS" ] || die "$dev/$slot still $state after $POLL_ATTEMPTS polls"
            sleep "$POLL_DELAY"
        done
        if [ "$state" = FAILED ]; then
            echo "error: App Store Connect rejected $dev/$slot:" >&2
            json "(d['data']['attributes'].get('assetDeliveryState') or {}).get('errors')" < "$WORK/shot.json" >&2 \
                || echo "(and its error list could not be read)" >&2
            exit 1
        fi
        dims="$(json "f\"{d['data']['attributes']['imageAsset']['width']} {d['data']['attributes']['imageAsset']['height']}\"" < "$WORK/shot.json")" \
            || die "no imageAsset dimensions for $dev/$slot"
        [ "$dims" = "$want_w $want_h" ] \
            || die "$dev/$slot is stored as ${dims/ /x}, expected ${want_w}x${want_h} -- transposed means sideways"
        check_rendition "$WORK/shot.json" "$dev/$slot" || exit 1
        echo "$shot_id" >> "$WORK/new-$dev"
        echo "uploaded $dev/$slot ($shot_id), $dims, landscape"
    done

    # Pin the slot order rather than trusting upload order.
    ids="$(sed 's/.*/{"type":"appScreenshots","id":"&"}/' "$WORK/new-$dev" | paste -sd, -)"
    api PATCH "$API/v1/appScreenshotSets/$set_id/relationships/appScreenshots" "{\"data\":[$ids]}" > /dev/null \
        || die "could not set the slot order of $dev set $set_id"
    echo "ok - $dev: 6 screenshots in slot order"
done
echo "Done. Check the listing in App Store Connect before submitting."
