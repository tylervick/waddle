#!/usr/bin/env python3
"""Reads an App Store Connect `GET /v1/appAssetLibraryRefData` document and
prints what it says about one screenshot slot, for Scripts/upload-screenshots.sh.

Usage: asset-library-specs.py REFDATA_JSON
Env:   DUO_GROUP           the placement group, e.g. IPHONE_DUO_PROFILE
       DUO_PLACEMENT_TYPE  the placement type, e.g. APP_SCREENSHOT

Output, one fact per line:
    limit N              the most placements the group holds on an app version
    WIDTH HEIGHT SPECID  one line per image size the group accepts

Exits non-zero, saying why, when the document does not offer the group for
that placement type, gives it no limit, or states a size as a range. The
caller compares exact sizes, so a range is a change in Apple's rules that a
person should read, not something to round.
"""
import json
import os
import sys


def main():
    group, kind = os.environ["DUO_GROUP"], os.environ["DUO_PLACEMENT_TYPE"]
    specs, limit = {}, None
    for datum in json.load(open(sys.argv[1]))["data"]:
        attrs = datum["attributes"]
        by_id = {s["specId"]: s for s in attrs.get("imageSpecs") or []}
        for placement_type in attrs.get("placementTypes") or []:
            if placement_type.get("placementTypeId") != kind:
                continue
            for mapping in placement_type.get("specMappings") or []:
                if mapping.get("placementGroupId") != group:
                    continue
                for spec_id in mapping.get("specs") or []:
                    if spec_id not in by_id:
                        sys.exit(f"error: {group} maps to spec {spec_id}, which the document does not define")
                    dim = by_id[spec_id]["dimensions"]
                    if dim["minWidth"] != dim["maxWidth"] or dim["minHeight"] != dim["maxHeight"]:
                        sys.exit(f"error: spec {spec_id} is a range, not an exact size: {dim}")
                    specs[(dim["minWidth"], dim["minHeight"])] = spec_id
        for feature in attrs.get("features") or []:
            if feature.get("featureId") != "APP_STORE_VERSIONS":
                continue
            for policy in feature.get("placementPolicies") or []:
                if policy.get("placementType") != kind:
                    continue
                for group_limit in policy.get("groupLimits") or []:
                    if group in (group_limit.get("groupIds") or []):
                        limit = group_limit["maxCount"]
    if not specs:
        sys.exit(f"error: no image spec is mapped to {group} for {kind}")
    if limit is None:
        sys.exit(f"error: no APP_STORE_VERSIONS limit names {group} for {kind}")
    print("limit", limit)
    for (width, height), spec_id in sorted(specs.items()):
        print(width, height, spec_id)


if __name__ == "__main__":
    main()
