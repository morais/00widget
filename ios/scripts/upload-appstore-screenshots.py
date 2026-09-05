#!/usr/bin/env python3
"""Replace 00Widget's App Store screenshots with promotional compositions.

Stages as many replacements as Apple's ten-image limit permits, verifies their
processing, then removes only the old assets needed to finish the replacement
and applies the intended order. Credentials and the bundle id follow the same
conventions as set-appclip-invocation.py and upload-testflight.sh.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
IOS_ROOT = SCRIPT_DIR.parent
REPO_ROOT = IOS_ROOT.parent
RAW_ROOT = REPO_ROOT / "artifacts" / "screenshots" / "raw"
PROMOTIONAL_ROOT = REPO_ROOT / "artifacts" / "screenshots" / "promotional"
AUTH_SCRIPT = SCRIPT_DIR / "set-appclip-invocation.py"

spec = importlib.util.spec_from_file_location("zw_appstore_auth", AUTH_SCRIPT)
if spec is None or spec.loader is None:
    sys.exit(f"Unable to load {AUTH_SCRIPT}")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


PROMOTIONAL_SETS = {
    "IOS": {
        "APP_IPHONE_61": (
            PROMOTIONAL_ROOT / "iphone-6.3",
            [
                "screenshot-home-widgets.png",
                "screenshot-home-insights.png",
                "screenshot-lock-activity.png",
                "screenshot-home-metrics.png",
                "screenshot-widgets.png",
                "screenshot-insights.png",
                "screenshot-activities.png",
            ],
        ),
        "APP_IPHONE_65": (
            PROMOTIONAL_ROOT / "iphone-6.5",
            [
                "screenshot-home-widgets.png",
                "screenshot-home-insights.png",
                "screenshot-lock-activity.png",
                "screenshot-home-metrics.png",
                "screenshot-widgets.png",
                "screenshot-insights.png",
                "screenshot-activities.png",
            ],
        ),
        "APP_IPAD_PRO_3GEN_129": (
            PROMOTIONAL_ROOT / "ipad",
            [
                "screenshot-home-widgets.png",
                "screenshot-home-insights.png",
                "screenshot-lock-activity.png",
                "screenshot-home-metrics.png",
                "screenshot-widgets.png",
                "screenshot-insights.png",
                "screenshot-activities.png",
            ],
        ),
    },
    "TV_OS": {
        "APP_APPLE_TV": (
            PROMOTIONAL_ROOT / "tvos",
            [
                "screenshot-tv-insights.png",
                "screenshot-tv-widgets.png",
                "screenshot-tv-card-detail.png",
            ],
        ),
    },
}


def expect(status, body, allowed, what):
    asc.die_on_permission(status, body, what)
    if status not in allowed:
        raise RuntimeError(f"{what} returned {status}: {json.dumps(body)[:800]}")
    return body


def project_version():
    text = (IOS_ROOT / "project.yml").read_text()
    match = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', text, re.M)
    return match.group(1) if match else None


def relationship(path, resource_type, ids):
    body = {"data": [{"type": resource_type, "id": value} for value in ids]}
    status, response = asc.call("PATCH", path, body)
    expect(status, response, {200, 204}, f"updating {resource_type} order")


def upload_parts(operations, data):
    for operation in operations:
        offset = operation["offset"]
        length = operation["length"]
        chunk = data[offset:offset + length]
        headers = {
            item["name"]: item["value"]
            for item in operation.get("requestHeaders", [])
        }
        request = urllib.request.Request(
            operation["url"], data=chunk, headers=headers,
            method=operation.get("method", "PUT"))
        try:
            with urllib.request.urlopen(request) as response:
                if response.status not in (200, 201):
                    raise RuntimeError(f"asset part upload returned {response.status}")
        except urllib.error.HTTPError as error:
            raise RuntimeError(
                f"asset part upload returned {error.code}: {error.read().decode()[:400]}") from error


def reserve_and_upload(set_id, path, tag):
    data = path.read_bytes()
    remote_name = f"{tag}-{path.name}"
    body = {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileSize": len(data), "fileName": remote_name},
            "relationships": {
                "appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id}
                }
            },
        }
    }
    status, response = asc.call("POST", "/v1/appScreenshots", body)
    reservation = expect(status, response, {201}, f"reserving {path.name}")["data"]
    screenshot_id = reservation["id"]
    operations = reservation["attributes"].get("uploadOperations") or []
    if not operations:
        raise RuntimeError(f"Apple returned no upload operations for {path.name}")
    upload_parts(operations, data)

    checksum = hashlib.md5(data).hexdigest()
    commit = {
        "data": {
            "type": "appScreenshots",
            "id": screenshot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
        }
    }
    status, response = asc.call("PATCH", f"/v1/appScreenshots/{screenshot_id}", commit)
    expect(status, response, {200}, f"committing {path.name}")
    return screenshot_id


def wait_until_complete(screenshot_id, name, timeout):
    deadline = time.time() + timeout
    while True:
        status, response = asc.call("GET", f"/v1/appScreenshots/{screenshot_id}")
        shot = expect(status, response, {200}, f"checking {name}")["data"]
        delivery = shot["attributes"].get("assetDeliveryState") or {}
        state = delivery.get("state")
        if state == "COMPLETE":
            return
        if state == "FAILED":
            raise RuntimeError(f"{name} failed processing: {json.dumps(delivery)}")
        if time.time() >= deadline:
            raise RuntimeError(f"timed out waiting for {name}; last state was {state}")
        time.sleep(3)


def delete_screenshot(screenshot_id, what):
    status, response = asc.call("DELETE", f"/v1/appScreenshots/{screenshot_id}")
    expect(status, response, {204}, f"deleting {what}")


def local_checksum(path):
    return hashlib.md5(path.read_bytes()).hexdigest()


def sha256_checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_promotional_provenance(directory, filenames):
    path = PROMOTIONAL_ROOT / "promotional-manifest.json"
    if not path.is_file():
        raise RuntimeError(
            f"{PROMOTIONAL_ROOT} has no promotional manifest; run "
            "marketing/screenshots/capture-all.sh before publishing"
        )
    manifest = json.loads(path.read_text())
    if manifest.get("sourceRoot") != str(RAW_ROOT.resolve()):
        raise RuntimeError(f"{path} does not reference the canonical raw screenshot tree")
    if manifest.get("outputRoot") != str(PROMOTIONAL_ROOT.resolve()):
        raise RuntimeError(f"{path} does not reference the canonical promotional tree")

    matching_sets = [
        item for item in (manifest.get("sets") or [])
        if item.get("deviceSet") == directory.name
    ]
    if len(matching_sets) != 1:
        raise RuntimeError(f"{path} does not contain exactly one {directory.name} set")
    recorded = {
        item.get("filename"): item
        for item in (matching_sets[0].get("files") or [])
        if item.get("filename")
    }
    errors = []
    for filename in filenames:
        entry = recorded.get(filename) or {}
        output_checksum = sha256_checksum(directory / filename)
        source_checksum = sha256_checksum(RAW_ROOT / directory.name / filename)
        if (
            entry.get("outputSha256") != output_checksum
            or entry.get("sourceSha256") != source_checksum
        ):
            errors.append(filename)
    if errors:
        raise RuntimeError(
            f"{path} does not prove these compositions came from the current raw captures: "
            + ", ".join(errors)
        )


def verify_set(item):
    expected = [
        (filename, local_checksum(item["directory"] / filename))
        for filename in item["filenames"]
    ]
    actual = item["old"]
    errors = []
    if len(actual) != len(expected):
        errors.append(f"expected {len(expected)} images, found {len(actual)}")
    for index, (filename, checksum) in enumerate(expected):
        if index >= len(actual):
            errors.append(f"position {index + 1}: missing {filename}")
            continue
        attributes = actual[index].get("attributes", {})
        remote_checksum = (attributes.get("sourceFileChecksum") or "").lower()
        state = (attributes.get("assetDeliveryState") or {}).get("state")
        if remote_checksum != checksum.lower():
            errors.append(
                f"position {index + 1}: expected {filename} ({checksum}), "
                f"found {attributes.get('fileName')} ({remote_checksum or 'no checksum'})"
            )
        if state != "COMPLETE":
            errors.append(
                f"position {index + 1}: {attributes.get('fileName', filename)} "
                f"delivery state is {state}"
            )
    if errors:
        raise RuntimeError(
            f"{item['platform']} {item['display_type']} does not match the canonical set:\n  "
            + "\n  ".join(errors)
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default=asc.bundle_id_from_project())
    parser.add_argument("--version", default=project_version())
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--wait", type=int, default=300)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument(
        "--verify-only", action="store_true",
        help="fail unless App Store Connect exactly matches local files and order",
    )
    parser.add_argument(
        "--allow-unprovenanced", action="store_true",
        help="publish existing files without verified promotional provenance",
    )
    args = parser.parse_args()
    if not args.bundle_id or not args.version:
        sys.exit("Bundle id and marketing version must be available or passed explicitly.")

    missing = [
        str(directory / filename)
        for platform in PROMOTIONAL_SETS.values()
        for directory, filenames in platform.values()
        for filename in filenames
        if not (directory / filename).is_file()
    ]
    if missing:
        sys.exit("Missing promotional screenshots:\n  " + "\n  ".join(missing))
    if not args.verify_only and not args.allow_unprovenanced:
        try:
            for platform in PROMOTIONAL_SETS.values():
                for directory, filenames in platform.values():
                    verify_promotional_provenance(directory, filenames)
        except RuntimeError as error:
            sys.exit(
                f"✗ {error}\n"
                "  Use --allow-unprovenanced only for an intentional one-time migration."
            )

    status, apps = asc.call("GET", f"/v1/apps?filter[bundleId]={args.bundle_id}&limit=10")
    app_data = expect(status, apps, {200}, "finding the app").get("data", [])
    if len(app_data) != 1:
        sys.exit(f"Expected one app with bundle id {args.bundle_id}, found {len(app_data)}")
    app_id = app_data[0]["id"]

    resolved = []
    for platform, capture_sets in PROMOTIONAL_SETS.items():
        status, versions = asc.call(
            "GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]={platform}&limit=50")
        versions = expect(status, versions, {200}, f"listing {platform} versions")["data"]
        matching = [v for v in versions if v["attributes"]["versionString"] == args.version]
        if len(matching) != 1:
            sys.exit(f"Expected one {platform} version {args.version}, found {len(matching)}")
        version_id = matching[0]["id"]

        status, localizations = asc.call(
            "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
            f"?filter[locale]={args.locale}&limit=50")
        localizations = expect(
            status, localizations, {200}, f"finding {platform} {args.locale} localization")["data"]
        if len(localizations) != 1:
            sys.exit(f"Expected one {platform} {args.locale} localization, found {len(localizations)}")
        localization_id = localizations[0]["id"]

        status, remote_sets = asc.call(
            "GET", f"/v1/appStoreVersionLocalizations/{localization_id}"
            "/appScreenshotSets?limit=50")
        remote_sets = expect(status, remote_sets, {200}, f"listing {platform} screenshot sets")["data"]
        by_type = {item["attributes"]["screenshotDisplayType"]: item for item in remote_sets}

        for display_type, (directory, filenames) in capture_sets.items():
            remote_set = by_type.get(display_type)
            if remote_set is None:
                body = {
                    "data": {
                        "type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": display_type},
                        "relationships": {
                            "appStoreVersionLocalization": {
                                "data": {
                                    "type": "appStoreVersionLocalizations",
                                    "id": localization_id,
                                }
                            }
                        },
                    }
                }
                status, response = asc.call("POST", "/v1/appScreenshotSets", body)
                remote_set = expect(
                    status, response, {201}, f"creating {display_type} screenshot set")["data"]
            set_id = remote_set["id"]
            status, current = asc.call(
                "GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")
            current = expect(status, current, {200}, f"listing {display_type} screenshots")["data"]
            if len(filenames) > 10:
                sys.exit(
                    f"{display_type} declares {len(filenames)} screenshots, exceeding "
                    "App Store Connect's 10-screenshot limit.")
            resolved.append({
                "platform": platform,
                "display_type": display_type,
                "set_id": set_id,
                "directory": directory,
                "filenames": filenames,
                "old": current,
            })

    for item in resolved:
        print(
            f"{item['platform']} {item['display_type']}: "
            f"replace {len(item['old'])} with {len(item['filenames'])}")
    if args.verify_only:
        verification_errors = []
        for item in resolved:
            try:
                verify_set(item)
                print(
                    f"✓ {item['platform']} {item['display_type']} "
                    "matches checksums and order"
                )
            except RuntimeError as error:
                verification_errors.append(str(error))
        if verification_errors:
            raise RuntimeError("\n".join(verification_errors))
        return
    if args.dry_run:
        return

    tag = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    created = []
    old_deleted = False
    try:
        for item in resolved:
            item["new"] = []
            capacity = max(0, 10 - len(item["old"]))
            item["staged"] = item["filenames"][:capacity]
            item["pending"] = item["filenames"][capacity:]
            for filename in item["staged"]:
                print(f"→ uploading {item['display_type']} {filename}")
                screenshot_id = reserve_and_upload(
                    item["set_id"], item["directory"] / filename, tag)
                item["new"].append(screenshot_id)
                created.append((screenshot_id, filename))
        for screenshot_id, filename in created:
            wait_until_complete(screenshot_id, filename, args.wait)
            print(f"  ✓ {filename} processed")

        for item in resolved:
            if item["pending"]:
                print(
                    f"  Apple permits 10 images; {len(item['staged'])} replacements are "
                    f"verified, now removing the old {item['display_type']} set"
                )
            for old in item["old"]:
                delete_screenshot(
                    old["id"], old["attributes"].get("fileName", old["id"]))
            old_deleted = True
            for filename in item["pending"]:
                print(f"→ uploading {item['display_type']} {filename}")
                screenshot_id = reserve_and_upload(
                    item["set_id"], item["directory"] / filename, tag)
                item["new"].append(screenshot_id)
                created.append((screenshot_id, filename))
                wait_until_complete(screenshot_id, filename, args.wait)
                print(f"  ✓ {filename} processed")
            relationship(
                f"/v1/appScreenshotSets/{item['set_id']}/relationships/appScreenshots",
                "appScreenshots",
                item["new"],
            )
            print(f"✓ replaced {item['display_type']} in the requested order")
    except Exception:
        if old_deleted:
            print(
                "✗ replacement stopped after an old set was removed; keeping every "
                "processed replacement so the next run can recover",
                file=sys.stderr,
            )
        else:
            print("✗ staging failed; removing newly created screenshots", file=sys.stderr)
            for screenshot_id, filename in reversed(created):
                try:
                    delete_screenshot(screenshot_id, filename)
                except Exception as cleanup_error:
                    print(f"  cleanup failed for {filename}: {cleanup_error}", file=sys.stderr)
        raise


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(f"✗ {error}")
