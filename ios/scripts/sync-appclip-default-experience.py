#!/usr/bin/env python3
"""Idempotently sync the App Store default App Clip experience.

The invocation URL remains in the gitignored ios/appstore.env, with
ios/appstore.env.sample as its committed template. It can also be provided with
ZW_APPCLIP_INVOCATION_URL or --url. All other canonical metadata and the header
asset live in the repository and are verified after every write.
"""

import argparse
import hashlib
import importlib.util
import json
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
IOS_ROOT = SCRIPT_DIR.parent
REPO_ROOT = IOS_ROOT.parent
AUTH_SCRIPT = SCRIPT_DIR / "set-appclip-invocation.py"
DEFAULT_HEADER = REPO_ROOT / "docs/brand/app-clip-header.png"
DEFAULT_SUBTITLE = "See a shared widget or Live Activity instantly."

spec = importlib.util.spec_from_file_location("zw_appstore_auth", AUTH_SCRIPT)
if spec is None or spec.loader is None:
    sys.exit(f"Unable to load {AUTH_SCRIPT}")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


def expect(status, body, allowed, what):
    asc.die_on_permission(status, body, what)
    if status not in allowed:
        raise RuntimeError(f"{what} returned {status}: {json.dumps(body)[:800]}")
    return body


def project_version():
    text = (IOS_ROOT / "project.yml").read_text()
    match = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', text, re.M)
    return match.group(1) if match else None


def upload_parts(operations, data):
    for operation in operations:
        offset = operation["offset"]
        length = operation["length"]
        headers = {
            item["name"]: item["value"]
            for item in operation.get("requestHeaders", [])
        }
        request = urllib.request.Request(
            operation["url"],
            data=data[offset:offset + length],
            headers=headers,
            method=operation.get("method", "PUT"),
        )
        try:
            with urllib.request.urlopen(request) as response:
                if response.status not in (200, 201):
                    raise RuntimeError(f"asset part upload returned {response.status}")
        except urllib.error.HTTPError as error:
            raise RuntimeError(
                f"asset part upload returned {error.code}: {error.read().decode()[:400]}"
            ) from error


def validate_header(path):
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError(f"{path} is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (1800, 1200):
        raise RuntimeError(
            f"{path} is {width}x{height}; the App Clip header must be 1800x1200"
        )
    return data, hashlib.md5(data).hexdigest()


def create_header(localization_id, path, data, checksum):
    payload = {
        "data": {
            "type": "appClipHeaderImages",
            "attributes": {"fileName": path.name, "fileSize": len(data)},
            "relationships": {
                "appClipDefaultExperienceLocalization": {
                    "data": {
                        "type": "appClipDefaultExperienceLocalizations",
                        "id": localization_id,
                    }
                }
            },
        }
    }
    status, response = asc.call("POST", "/v1/appClipHeaderImages", payload)
    image = expect(status, response, {201}, "reserving the App Clip header")["data"]
    operations = image["attributes"].get("uploadOperations") or []
    if not operations:
        raise RuntimeError("Apple returned no upload operations for the App Clip header")
    upload_parts(operations, data)
    image_id = image["id"]
    commit = {
        "data": {
            "type": "appClipHeaderImages",
            "id": image_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
        }
    }
    status, response = asc.call("PATCH", f"/v1/appClipHeaderImages/{image_id}", commit)
    expect(status, response, {200}, "committing the App Clip header")
    return image_id


def wait_for_header(image_id, timeout):
    deadline = time.time() + timeout
    while True:
        status, response = asc.call("GET", f"/v1/appClipHeaderImages/{image_id}")
        image = expect(status, response, {200}, "checking the App Clip header")["data"]
        state = (image["attributes"].get("assetDeliveryState") or {}).get("state")
        if state == "COMPLETE":
            return image
        if state == "FAILED":
            raise RuntimeError(
                "App Clip header processing failed: "
                + json.dumps(image["attributes"].get("assetDeliveryState"))
            )
        if time.time() >= deadline:
            raise RuntimeError(
                f"timed out waiting for the App Clip header; last state was {state}"
            )
        time.sleep(3)


def app_and_version(bundle_id, version):
    encoded_bundle = urllib.parse.quote(bundle_id, safe="")
    status, apps = asc.call(
        "GET", f"/v1/apps?filter[bundleId]={encoded_bundle}&limit=10"
    )
    app_data = expect(status, apps, {200}, "finding the app").get("data", [])
    if len(app_data) != 1:
        raise RuntimeError(
            f"expected one app with bundle id {bundle_id}, found {len(app_data)}"
        )
    app_id = app_data[0]["id"]
    status, versions = asc.call(
        "GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=50"
    )
    version_data = expect(status, versions, {200}, "listing iOS versions")["data"]
    matches = [item for item in version_data if item["attributes"]["versionString"] == version]
    if len(matches) != 1:
        raise RuntimeError(f"expected one iOS version {version}, found {len(matches)}")
    return app_id, matches[0]["id"]


def find_experience(app_id, version_id):
    status, clips = asc.call("GET", f"/v1/apps/{app_id}/appClips?limit=200")
    clip_data = expect(status, clips, {200}, "listing App Clips")["data"]
    if len(clip_data) != 1:
        raise RuntimeError(f"expected one App Clip, found {len(clip_data)}")
    clip_id = clip_data[0]["id"]
    status, response = asc.call(
        "GET",
        f"/v1/appClips/{clip_id}/appClipDefaultExperiences"
        "?include=releaseWithAppStoreVersion&limit=200",
    )
    experiences = expect(
        status, response, {200}, "listing default App Clip experiences"
    )["data"]
    matches = []
    for experience in experiences:
        related = (
            experience.get("relationships", {})
            .get("releaseWithAppStoreVersion", {})
            .get("data")
        )
        if related and related.get("id") == version_id:
            matches.append(experience)
    if len(matches) > 1:
        raise RuntimeError("more than one default App Clip experience targets this version")
    return clip_id, matches[0] if matches else None


def create_experience(clip_id, version_id, action):
    payload = {
        "data": {
            "type": "appClipDefaultExperiences",
            "attributes": {"action": action},
            "relationships": {
                "appClip": {"data": {"type": "appClips", "id": clip_id}},
                "releaseWithAppStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                },
            },
        }
    }
    status, response = asc.call("POST", "/v1/appClipDefaultExperiences", payload)
    return expect(status, response, {201}, "creating the default App Clip experience")["data"]


def update_resource(resource_type, resource_id, attributes, what):
    payload = {
        "data": {"type": resource_type, "id": resource_id, "attributes": attributes}
    }
    status, response = asc.call("PATCH", f"/v1/{resource_type}/{resource_id}", payload)
    expect(status, response, {200}, what)


def create_review_detail(experience_id, invocation_url):
    payload = {
        "data": {
            "type": "appClipAppStoreReviewDetails",
            "attributes": {"invocationUrls": [invocation_url]},
            "relationships": {
                "appClipDefaultExperience": {
                    "data": {
                        "type": "appClipDefaultExperiences",
                        "id": experience_id,
                    }
                }
            },
        }
    }
    status, response = asc.call("POST", "/v1/appClipAppStoreReviewDetails", payload)
    return expect(status, response, {201}, "creating App Clip review details")["data"]


def create_localization(experience_id, locale, subtitle):
    payload = {
        "data": {
            "type": "appClipDefaultExperienceLocalizations",
            "attributes": {"locale": locale, "subtitle": subtitle},
            "relationships": {
                "appClipDefaultExperience": {
                    "data": {
                        "type": "appClipDefaultExperiences",
                        "id": experience_id,
                    }
                }
            },
        }
    }
    status, response = asc.call(
        "POST", "/v1/appClipDefaultExperienceLocalizations", payload
    )
    return expect(status, response, {201}, "creating App Clip localization")["data"]


def report_or_apply(condition, description, mode, apply):
    if condition:
        print(f"✓ {description}")
        return
    if mode == "verify":
        raise RuntimeError(f"App Store Connect mismatch: {description}")
    if mode == "dry-run":
        print(f"→ would set {description}")
        return
    apply()
    print(f"✓ set {description}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default=asc.bundle_id_from_project())
    parser.add_argument("--version", default=project_version())
    parser.add_argument("--url", default=asc.appclip_invocation_url())
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--subtitle", default=DEFAULT_SUBTITLE)
    parser.add_argument("--action", choices=("OPEN", "VIEW", "PLAY"), default="VIEW")
    parser.add_argument("--header", type=Path, default=DEFAULT_HEADER)
    parser.add_argument("--wait", type=int, default=300)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if not args.bundle_id or not args.version:
        sys.exit("Bundle id and marketing version must be available or passed explicitly.")
    if not args.url:
        sys.exit(
            "No invocation URL: pass --url, set ZW_APPCLIP_INVOCATION_URL, or copy "
            "ios/appstore.env.sample to ios/appstore.env and edit it."
        )
    parsed_url = urllib.parse.urlsplit(args.url)
    if parsed_url.scheme != "https" or not parsed_url.netloc or parsed_url.fragment:
        sys.exit("The App Review invocation URL must be an HTTPS URL without a fragment.")
    header_data, header_checksum = validate_header(args.header)
    mode_name = "verify" if args.verify_only else "dry-run" if args.dry_run else "sync"

    app_id, version_id = app_and_version(args.bundle_id, args.version)
    clip_id, experience = find_experience(app_id, version_id)
    if experience is None:
        if mode_name == "verify":
            raise RuntimeError(
                f"App Store Connect has no default App Clip experience for iOS {args.version}"
            )
        if mode_name == "dry-run":
            print(f"→ would create the default App Clip experience for iOS {args.version}")
            print(f"→ would set action {args.action}, {args.locale} subtitle, review URL, and header")
            return
        experience = create_experience(clip_id, version_id, args.action)
        print(f"✓ created the default App Clip experience for iOS {args.version}")

    experience_id = experience["id"]
    report_or_apply(
        experience.get("attributes", {}).get("action") == args.action,
        f"action {args.action}",
        mode_name,
        lambda: update_resource(
            "appClipDefaultExperiences",
            experience_id,
            {"action": args.action},
            "updating the App Clip action",
        ),
    )

    status, review_response = asc.call(
        "GET", f"/v1/appClipDefaultExperiences/{experience_id}/appClipAppStoreReviewDetail"
    )
    review_data = expect(
        status, review_response, {200}, "reading App Clip review details"
    ).get("data")
    review_matches = bool(
        review_data
        and review_data.get("attributes", {}).get("invocationUrls") == [args.url]
    )

    def apply_review():
        if review_data:
            update_resource(
                "appClipAppStoreReviewDetails",
                review_data["id"],
                {"invocationUrls": [args.url]},
                "updating App Clip review details",
            )
        else:
            create_review_detail(experience_id, args.url)

    report_or_apply(
        review_matches,
        f"App Review invocation URL {args.url}",
        mode_name,
        apply_review,
    )

    encoded_locale = urllib.parse.quote(args.locale, safe="")
    status, localization_response = asc.call(
        "GET",
        f"/v1/appClipDefaultExperiences/{experience_id}/"
        f"appClipDefaultExperienceLocalizations?filter[locale]={encoded_locale}&limit=50",
    )
    localizations = expect(
        status, localization_response, {200}, "reading App Clip localizations"
    )["data"]
    if len(localizations) > 1:
        raise RuntimeError(f"found more than one App Clip localization for {args.locale}")
    localization = localizations[0] if localizations else None
    localization_matches = bool(
        localization
        and localization.get("attributes", {}).get("subtitle") == args.subtitle
    )

    if not localization_matches:
        if mode_name == "verify":
            raise RuntimeError(
                f"App Store Connect mismatch: {args.locale} subtitle {args.subtitle!r}"
            )
        if mode_name == "dry-run":
            print(f"→ would set {args.locale} subtitle {args.subtitle!r}")
            if localization is None:
                print(f"→ would upload header {args.header}")
            return
        if localization:
            update_resource(
                "appClipDefaultExperienceLocalizations",
                localization["id"],
                {"subtitle": args.subtitle},
                "updating App Clip localization",
            )
        else:
            localization = create_localization(
                experience_id, args.locale, args.subtitle
            )
        print(f"✓ set {args.locale} subtitle {args.subtitle!r}")
    else:
        print(f"✓ {args.locale} subtitle {args.subtitle!r}")

    localization_id = localization["id"]
    status, image_response = asc.call(
        "GET",
        f"/v1/appClipDefaultExperienceLocalizations/{localization_id}/appClipHeaderImage",
    )
    image_data = expect(
        status, image_response, {200}, "reading the App Clip header"
    ).get("data")
    image_matches = bool(
        image_data
        and image_data.get("attributes", {}).get("sourceFileChecksum", "").lower()
        == header_checksum.lower()
        and (image_data.get("attributes", {}).get("assetDeliveryState") or {}).get("state")
        == "COMPLETE"
    )

    def apply_header():
        if image_data:
            status, response = asc.call(
                "DELETE", f"/v1/appClipHeaderImages/{image_data['id']}"
            )
            expect(status, response, {204}, "deleting the old App Clip header")
        image_id = create_header(
            localization_id, args.header, header_data, header_checksum
        )
        uploaded = wait_for_header(image_id, args.wait)
        remote_checksum = uploaded["attributes"].get("sourceFileChecksum", "").lower()
        if remote_checksum != header_checksum.lower():
            raise RuntimeError(
                f"uploaded App Clip header checksum is {remote_checksum}, expected {header_checksum}"
            )

    report_or_apply(
        image_matches,
        f"header {args.header.name} checksum {header_checksum}",
        mode_name,
        apply_header,
    )


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(f"✗ {error}")
