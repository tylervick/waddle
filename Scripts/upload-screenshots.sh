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
# The iPhone Duo set (--device duo) takes a different road (issue #409).
# `ScreenshotDisplayType` has no Duo value, so there is no appScreenshotSet to
# fill; the slot is the asset library's placement group IPHONE_DUO_PROFILE
# (metadata.md §12). Each file becomes an appAssetLibraryImage, and an
# appAssetLibraryPlacement ties that image to the version's en-US localization.
# What differs from a set, and why the Duo leg is written as it is:
#
#   * A placement belongs to ONE version localization; the image behind it can
#     be shared by many. So only placements are deleted, never images, and
#     only placements read from the target version's own localization that
#     also name that localization in their relationship.
#   * The group holds 10, like a set, so the old placements still go first.
#   * A Duo screenshot may be portrait or landscape, of the outer or the inner
#     display: four exact sizes, checked locally and again against Apple's
#     reference data. The stored image must come back the same way round.
#   * The request shapes for the writes come from Apple's OpenAPI
#     specification 4.6.1. The reads were run against the live app; the WRITES
#     HAD NOT BEEN SENT TO APPLE when this was written (version 1.5 was in
#     review). Treat the first --apply as the experiment it is, on an editable
#     version, and record what Apple answers in metadata.md §12.
#
# Usage:
#   Scripts/upload-screenshots.sh [--apply] [--version X.Y] [--device iphone|ipad|duo|all]
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

# The asset-library placement group and type of an iPhone Duo screenshot, and
# the four sizes Apple accepts there (exact, not ranges).
DUO_GROUP="IPHONE_DUO_PROFILE"
DUO_PLACEMENT_TYPE="APP_SCREENSHOT"
DUO_SIZES="1398x2034 2034x1398 2007x2853 2853x2007"
export DUO_GROUP DUO_PLACEMENT_TYPE

usage() { echo "usage: $0 [--apply] [--version X.Y] [--device iphone|ipad|duo|all]" >&2; exit 2; }
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
# DEVICES are uploaded as appScreenshotSets; DUO=1 adds the asset-library
# leg, which runs last so that its untried writes cannot stop the other two.
DEVICES=""; DUO=0
case "$DEVICE" in
    iphone) DEVICES="iphone" ;;
    ipad) DEVICES="ipad" ;;
    duo) DUO=1 ;;
    all) DEVICES="iphone ipad"; DUO=1 ;;
    *) usage ;;
esac

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
device_dir()  { case "$1" in iphone) echo "iphone-6.9" ;; ipad) echo "ipad-13" ;; duo) echo "iphone-duo" ;; esac; }
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
# The Duo set: the same six slots, each file exactly one of the four sizes.
# The size is remembered per slot because, unlike the two sets above, the
# files need not all be the same way round.
if [ "$DUO" = 1 ]; then
    for slot in $SLOTS; do
        f="$SHOTS_DIR/$(device_dir duo)/$slot.png"
        [ -f "$f" ] || die "missing $f"
        info="$(png_info "$f")" || die "$f is not a readable PNG"
        read -r w h exif <<EOF
$info
EOF
        [ "$exif" = 0 ] || die "$f carries an eXIf chunk -- App Store Connect would rotate it (metadata.md §12)"
        case " $DUO_SIZES " in
            *" ${w}x${h} "*) ;;
            *) die "$f is ${w}x${h}; an iPhone Duo screenshot is exactly one of: $DUO_SIZES" ;;
        esac
        echo "$w $h" > "$WORK/duo-size-$slot"
    done
    # Said here, before the version is looked at, so that a dry run against a
    # version that cannot be edited still shows what it was asked to place.
    echo "iPhone Duo set, in slot order:"
    for slot in $SLOTS; do
        read -r w h < "$WORK/duo-size-$slot"
        echo "  $(device_dir duo)/$slot.png ${w}x${h} -> $DUO_PLACEMENT_TYPE in $DUO_GROUP"
    done
fi
echo "ok - local files: $(( $(echo $DEVICES | wc -w) + DUO )) device set(s) x 6, sizes and orientation checked"

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

# None of the screenshot-set reads below run when only the Duo set was asked
# for: it touches no set, and a set that was never resolved cannot be changed.
: > "$WORK/target-sets"
if [ -n "$DEVICES" ]; then
    sets_of "$VERSION_ID" > "$WORK/target-sets" || die "could not list version $VERSION's screenshot sets"
fi

# 2. Every set on a version that is NOT editable -- the live listing and
# anything in review -- is off limits. Collect their ids once.
: > "$WORK/protected-sets"
json "[f'{v[\"id\"]} {v[\"attributes\"].get(\"appVersionState\") or v[\"attributes\"].get(\"appStoreState\")}' for v in d['data'] if v['id'] != env['VERSION_ID']]" \
    < "$WORK/versions.json" > "$WORK/other-versions" || die "could not read the version list"
while read -r vid vstate; do
    [ -n "$vid" ] || continue
    [ -n "$DEVICES" ] || continue
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

# 4. The Duo set: the library, the slot as Apple states it, and what the
# version already has there. All reads; this is everything a dry run proves.
if [ "$DUO" = 1 ]; then
    resp="$(api GET "$API/v1/apps/$APP_ID/assetLibrary")" || die "could not read the app's asset library"
    LIBRARY_ID="$(printf '%s' "$resp" | json "d['data']['id']")" || die "the app's asset library has no id"
    export LIBRARY_ID

    # Each file must match a spec the reference data maps to this group for
    # this placement type, and the six must fit under the group's limit -- so
    # a size Apple withdraws, or a renamed group, stops the run here rather
    # than at the fourth upload.
    api GET "$API/v1/appAssetLibraryRefData" > "$WORK/refdata.json" || die "could not read the asset library reference data"
    python3 "$ROOT/Scripts/asset-library-specs.py" "$WORK/refdata.json" > "$WORK/duo-specs" \
        || die "the asset library reference data does not offer $DUO_PLACEMENT_TYPE in $DUO_GROUP as expected"
    duo_limit="$(awk '$1 == "limit" { print $2 }' "$WORK/duo-specs")"
    [ "$(echo $SLOTS | wc -w)" -le "$duo_limit" ] \
        || die "$DUO_GROUP holds at most $duo_limit screenshots; this set has $(echo $SLOTS | wc -w | tr -d ' ')"
    for slot in $SLOTS; do
        read -r w h < "$WORK/duo-size-$slot"
        spec="$(awk -v w="$w" -v h="$h" '$1 == w && $2 == h { print $3; exit }' "$WORK/duo-specs")"
        [ -n "$spec" ] || die "App Store Connect lists no ${w}x${h} spec for $DUO_GROUP ($slot.png); it lists: $(awk '$1 != "limit" { printf "%sx%s ", $1, $2 }' "$WORK/duo-specs")"
    done

    LOC_ID="$(asc_localization_id "$VERSION_ID")" || die "could not list version $VERSION's localizations"
    [ -n "$LOC_ID" ] || die "version $VERSION has no $LOCALE localization to place screenshots on"
    export LOC_ID
    # The version's placements in the Duo group. The endpoint is scoped to
    # this localization, and every row is still required to say so itself:
    # these are the ids --apply deletes, and a placement of another version
    # (the live listing's, say) must never be among them.
    api GET "$API/v1/appStoreVersionLocalizations/$LOC_ID/placements?filter%5BplacementGroup%5D=$DUO_GROUP&include=appStoreVersionLocalization&limit=50" \
        > "$WORK/duo-old.json" || die "could not list version $VERSION's $DUO_GROUP placements"
    more="$(json "(d.get('links') or {}).get('next') or ''" < "$WORK/duo-old.json")" || die "could not read the $DUO_GROUP placements"
    [ -z "$more" ] || die "version $VERSION has more than 50 $DUO_GROUP placements; refusing to act on a partial list"
    json "[p['id'] for p in d['data'] if p['attributes'].get('placementGroup') != env['DUO_GROUP'] or (((p.get('relationships') or {}).get('appStoreVersionLocalization') or {}).get('data') or {}).get('id') != env['LOC_ID']]" \
        < "$WORK/duo-old.json" > "$WORK/duo-foreign" || die "could not read the $DUO_GROUP placements"
    [ ! -s "$WORK/duo-foreign" ] \
        || die "placement $(head -1 "$WORK/duo-foreign") was listed for version $VERSION but does not name its localization and $DUO_GROUP -- refusing to touch it"
    json "[p['id'] for p in d['data']]" < "$WORK/duo-old.json" > "$WORK/old-duo" || die "could not read the $DUO_GROUP placements"
    echo "ok - duo: asset library $LIBRARY_ID; localization $LOC_ID holds $(grep -c . "$WORK/old-duo" || true) placement(s) in $DUO_GROUP (limit $duo_limit)"
fi

if [ "$APPLY" = 0 ]; then
    echo "dry run: would replace them with $SHOTS_DIR/<device>/{$(echo $SLOTS | tr ' ' ',')}.png in that order."
    echo "Re-run with --apply to upload."
    exit 0
fi

# ---- apply ----------------------------------------------------------------

# The rendition check: fetch the stored image at a bounding box and confirm it
# came back the way round the file is -- landscape, unless told portrait.
# Reported width/height alone missed the sideways store.
check_rendition() { # resource-json-file, label, [portrait]
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
    if [ "${3:-landscape}" = portrait ]; then
        [ "$rh" -gt "$rw" ] || { echo "error: $2 renders ${rw}x${rh} -- stored sideways" >&2; return 1; }
    else
        [ "$rw" -gt "$rh" ] || { echo "error: $2 renders ${rw}x${rh} -- stored sideways" >&2; return 1; }
    fi
}

# Sends FILE's bytes exactly as a reservation's uploadOperations describe.
upload_parts() { # file, reservation-json-file, label
    local f="$1" label="$3" method url offset length headers old_ifs h
    json "[f'{o[\"method\"]}\t{o[\"url\"]}\t{o[\"offset\"]}\t{o[\"length\"]}\t' + '\x1f'.join(h['name'] + ': ' + h['value'] for h in (o.get('requestHeaders') or [])) for o in d['data']['attributes']['uploadOperations']]" \
        < "$2" > "$WORK/ops" || die "no uploadOperations for $label"
    [ -s "$WORK/ops" ] || die "no uploadOperations for $label"
    while IFS="$(printf '\t')" read -r method url offset length headers; do
        python3 -c 'import sys; f=open(sys.argv[1],"rb"); f.seek(int(sys.argv[2])); sys.stdout.buffer.write(f.read(int(sys.argv[3])))' \
            "$f" "$offset" "$length" > "$WORK/part"
        set -- -sS -f --connect-timeout 10 --max-time 300 -X "$method" --data-binary "@$WORK/part" -o /dev/null
        if [ -n "$headers" ]; then
            old_ifs="$IFS"; IFS="$(printf '\037')"
            for h in $headers; do set -- "$@" -H "$h"; done
            IFS="$old_ifs"
        fi
        curl "$@" "$url" || die "upload of $label failed at offset $offset"
    done < "$WORK/ops"
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
        upload_parts "$f" "$WORK/reserved.json" "$dev/$slot"

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
# ---- apply: the iPhone Duo set, through the asset library ------------------

# A JSON:API request body, built by json.dumps from the environment: every id
# in it came from an API response and must stay data.
duo_body() { # image | uploaded | placement | order
    python3 -c '
import json, os, sys
e = os.environ
ref = lambda kind, key: {"data": {"type": kind, "id": e[key]}}
kind = sys.argv[1]
if kind == "image":
    doc = {"type": "appAssetLibraryImages",
           "attributes": {"category": "APP_SCREENSHOTS_AND_PREVIEWS",
                          "fileName": e["FILE_NAME"], "fileSize": int(e["FILE_SIZE"])},
           "relationships": {"assetLibrary": ref("appAssetLibraries", "LIBRARY_ID")}}
elif kind == "uploaded":
    doc = {"type": "appAssetLibraryImages", "id": e["IMAGE_ID"], "attributes": {"uploaded": True}}
elif kind == "placement":
    doc = {"type": "appAssetLibraryPlacements",
           "attributes": {"placementType": e["DUO_PLACEMENT_TYPE"], "placementGroup": e["DUO_GROUP"]},
           "relationships": {"image": ref("appAssetLibraryImages", "IMAGE_ID"),
                             "appStoreVersionLocalization": ref("appStoreVersionLocalizations", "LOC_ID")}}
elif kind == "order":
    doc = {"type": "appAssetLibraryPlacementOrderingRequests",
           "attributes": {"placementGroup": e["DUO_GROUP"]},
           "relationships": {"orderedPlacements": {"data": [
                                 {"type": "appAssetLibraryPlacements", "id": i} for i in e["PLACEMENT_IDS"].split()]},
                             "appStoreVersionLocalization": ref("appStoreVersionLocalizations", "LOC_ID")}}
else:
    sys.exit("unknown body kind " + kind)
print(json.dumps({"data": doc}))
' "$1"
}

if [ "$DUO" = 1 ]; then
    # Delete first, for the same reason as a set: the group's limit leaves no
    # room for six new beside six old. Placements only -- the images stay in
    # the library, where another version's placement may still use them.
    while read -r old; do
        [ -n "$old" ] || continue
        api DELETE "$API/v1/appAssetLibraryPlacements/$old" > /dev/null || die "could not delete placement $old"
        echo "deleted duo placement $old"
    done < "$WORK/old-duo"

    : > "$WORK/new-duo"
    for slot in $SLOTS; do
        f="$SHOTS_DIR/$(device_dir duo)/$slot.png"
        read -r want_w want_h < "$WORK/duo-size-$slot"
        way=landscape; [ "$want_w" -gt "$want_h" ] || way=portrait
        # The library is one list for every device, and the other two sets'
        # files are already in it under these slot names; say which this is.
        body="$(FILE_NAME="iphone-duo-$slot.png" FILE_SIZE="$(wc -c < "$f" | tr -d ' ')" duo_body image)" \
            || die "could not build the image body for duo/$slot"
        api POST "$API/v1/appAssetLibraryImages" "$body" > "$WORK/reserved.json" || die "could not reserve duo/$slot"
        IMAGE_ID="$(json "d['data']['id']" < "$WORK/reserved.json")" || die "no id in the reservation for duo/$slot"
        export IMAGE_ID
        upload_parts "$f" "$WORK/reserved.json" "duo/$slot"
        # No sourceFileChecksum here: appAssetLibraryImages has no such field.
        api PATCH "$API/v1/appAssetLibraryImages/$IMAGE_ID" "$(duo_body uploaded)" > /dev/null \
            || die "could not commit duo/$slot"

        # Wait for Apple to process it, then verify it is the right way up.
        n=0; state=""
        while :; do
            api GET "$API/v1/appAssetLibraryImages/$IMAGE_ID" > "$WORK/shot.json" || die "could not read back duo/$slot"
            state="$(json "d['data']['attributes'].get('state') or ''" < "$WORK/shot.json")" \
                || die "unreadable state for duo/$slot"
            case "$state" in ''|AWAITING_UPLOAD|UPLOAD_COMPLETE) ;; *) break ;; esac
            n=$((n + 1))
            [ "$n" -lt "$POLL_ATTEMPTS" ] || die "duo/$slot still ${state:-without a state} after $POLL_ATTEMPTS polls"
            sleep "$POLL_DELAY"
        done
        if [ "$state" = FAILED ]; then
            echo "error: App Store Connect rejected duo/$slot:" >&2
            json "d['data']['attributes'].get('stateDetails')" < "$WORK/shot.json" >&2 \
                || echo "(and its state details could not be read)" >&2
            exit 1
        fi
        dims="$(json "f\"{d['data']['attributes']['imageAsset']['width']} {d['data']['attributes']['imageAsset']['height']}\"" < "$WORK/shot.json")" \
            || die "no imageAsset dimensions for duo/$slot (state $state)"
        [ "$dims" = "$want_w $want_h" ] \
            || die "duo/$slot is stored as ${dims/ /x}, expected ${want_w}x${want_h} -- transposed means sideways"
        check_rendition "$WORK/shot.json" "duo/$slot" "$way" || exit 1

        api POST "$API/v1/appAssetLibraryPlacements" "$(duo_body placement)" > "$WORK/placed.json" \
            || die "could not place duo/$slot in $DUO_GROUP (its image $IMAGE_ID stays in the library, unplaced)"
        placement_id="$(json "d['data']['id']" < "$WORK/placed.json")" || die "no id in the placement of duo/$slot"
        echo "$placement_id" >> "$WORK/new-duo"
        echo "uploaded duo/$slot (image $IMAGE_ID, placement $placement_id), $dims, $way"
    done

    # Pin the slot order rather than trusting creation order.
    PLACEMENT_IDS="$(paste -sd' ' - < "$WORK/new-duo")"
    export PLACEMENT_IDS
    api POST "$API/v1/appAssetLibraryPlacementOrderingRequests" "$(duo_body order)" > /dev/null \
        || die "could not set the slot order of the $DUO_GROUP placements"

    # Read the group back as App Store Connect now holds it: this, not the
    # 201s above, is the evidence that the set is on the version.
    api GET "$API/v1/appStoreVersionLocalizations/$LOC_ID/placements?filter%5BplacementGroup%5D=$DUO_GROUP&include=image&sort=placementGroupPosition&limit=50" \
        > "$WORK/duo-now.json" || die "could not read back the $DUO_GROUP placements"
    json "(lambda images: [f\"  {p['id']} {p['attributes'].get('state')} {(images.get(p['relationships']['image']['data']['id']) or {}).get('fileName')} {((images.get(p['relationships']['image']['data']['id']) or {}).get('imageAsset') or {}).get('width')}x{((images.get(p['relationships']['image']['data']['id']) or {}).get('imageAsset') or {}).get('height')}\" for p in d['data']])({i['id']: i['attributes'] for i in d.get('included') or [] if i['type'] == 'appAssetLibraryImages'})" \
        < "$WORK/duo-now.json" > "$WORK/duo-readback" || die "could not read the $DUO_GROUP read-back"
    echo "read back $DUO_GROUP on version $VERSION:"
    cat "$WORK/duo-readback"
    json "[p['id'] for p in d['data']]" < "$WORK/duo-now.json" > "$WORK/duo-now-ids" || die "could not read the $DUO_GROUP read-back"
    cmp -s "$WORK/new-duo" "$WORK/duo-now-ids" \
        || die "the $DUO_GROUP placements read back are not the six just placed, in slot order (see above)"
    ! grep -q ' FAILED ' "$WORK/duo-readback" || die "a $DUO_GROUP placement is FAILED (see above)"
    echo "ok - duo: 6 screenshots placed in $DUO_GROUP in slot order"
fi
echo "Done. Check the listing in App Store Connect before submitting."
