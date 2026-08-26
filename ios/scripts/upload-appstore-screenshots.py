#!/usr/bin/env python3
"""Replace 00Widget's App Store screenshots with the locally captured sets.

Uploads every replacement alongside the current screenshots, waits for Apple to
finish processing all of them, and only then deletes the old assets and applies
the intended order. Credentials and the bundle id follow the same conventions
as set-appclip-invocation.py and upload-testflight.sh.
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
AUTH_SCRIPT = SCRIPT_DIR / "set-appclip-invocation.py"

spec = importlib.util.spec_from_file_location("zw_appstore_auth", AUTH_SCRIPT)
if spec is None or spec.loader is None:
    sys.exit(f"Unable to load {AUTH_SCRIPT}")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


CAPTURE_SETS = {
    "IOS": {
        "APP_IPHONE_61": (
            IOS_ROOT / "build/screenshots",
            [
                "screenshot-widgets.png",
                "screenshot-home-widgets.png",
                "screenshot-activities.png",
                "screenshot-insights.png",
                "screenshot-breakdown.png",
                "screenshot-home-insights.png",
            ],
        ),
        "APP_IPHONE_65": (
            IOS_ROOT / "build/screenshots/iphone-6.5",
            [
                "screenshot-widgets.png",
                "screenshot-home-widgets.png",
                "screenshot-activities.png",
                "screenshot-insights.png",
                "screenshot-breakdown.png",
            ],
        ),
        "APP_IPAD_PRO_3GEN_129": (
            IOS_ROOT / "build/screenshots/ipad",
            [
                "screenshot-widgets.png",
                "screenshot-home-widgets.png",
                "screenshot-activities.png",
                "screenshot-insights.png",
                "screenshot-breakdown.png",
                "screenshot-home-insights.png",
            ],
        ),
    },
    "TV_OS": {
        "APP_APPLE_TV": (
            IOS_ROOT / "build/screenshots/tvos",
            [
                "screenshot-tv-widgets.png",
                "screenshot-tv-insights.png",
                "screenshot-tv-activities.png",
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default=asc.bundle_id_from_project())
    parser.add_argument("--version", default=project_version())
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--wait", type=int, default=300)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.bundle_id or not args.version:
        sys.exit("Bundle id and marketing version must be available or passed explicitly.")

    missing = [
        str(directory / filename)
        for platform in CAPTURE_SETS.values()
        for directory, filenames in platform.values()
        for filename in filenames
        if not (directory / filename).is_file()
    ]
    if missing:
        sys.exit("Missing captured screenshots:\n  " + "\n  ".join(missing))

    status, apps = asc.call("GET", f"/v1/apps?filter[bundleId]={args.bundle_id}&limit=10")
    app_data = expect(status, apps, {200}, "finding the app").get("data", [])
    if len(app_data) != 1:
        sys.exit(f"Expected one app with bundle id {args.bundle_id}, found {len(app_data)}")
    app_id = app_data[0]["id"]

    resolved = []
    for platform, capture_sets in CAPTURE_SETS.items():
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
            if len(current) + len(filenames) > 10:
                sys.exit(
                    f"{display_type} has {len(current)} screenshots; staging {len(filenames)} "
                    "would exceed App Store Connect's 10-screenshot limit.")
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
    if args.dry_run:
        return

    tag = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    created = []
    try:
        for item in resolved:
            item["new"] = []
            for filename in item["filenames"]:
                print(f"→ uploading {item['display_type']} {filename}")
                screenshot_id = reserve_and_upload(
                    item["set_id"], item["directory"] / filename, tag)
                item["new"].append(screenshot_id)
                created.append((screenshot_id, filename))
        for screenshot_id, filename in created:
            wait_until_complete(screenshot_id, filename, args.wait)
            print(f"  ✓ {filename} processed")
    except Exception:
        print("✗ staging failed; removing newly created screenshots", file=sys.stderr)
        for screenshot_id, filename in reversed(created):
            try:
                delete_screenshot(screenshot_id, filename)
            except Exception as cleanup_error:
                print(f"  cleanup failed for {filename}: {cleanup_error}", file=sys.stderr)
        raise

    for item in resolved:
        for old in item["old"]:
            delete_screenshot(old["id"], old["attributes"].get("fileName", old["id"]))
        relationship(
            f"/v1/appScreenshotSets/{item['set_id']}/relationships/appScreenshots",
            "appScreenshots",
            item["new"],
        )
        print(f"✓ replaced {item['display_type']} in the requested order")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(f"✗ {error}")
