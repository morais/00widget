#!/usr/bin/env python3
"""Sync the repository's canonical localized App Store metadata.

Name and subtitle are app-level fields in ``appInfoLocalizations``. Description,
keywords, and promotional text are version- and platform-level fields in
``appStoreVersionLocalizations``. Keeping those resource types separate is
important: a successful version-localization update does not cover the app name
or subtitle.

The default mode is apply. Every apply is followed by a fresh read and exact
verification. Dry-run performs reads only, and verify-only fails on any drift.
"""

import argparse
import importlib.util
import json
import re
import sys
import urllib.parse
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
IOS_ROOT = SCRIPT_DIR.parent
AUTH_SCRIPT = SCRIPT_DIR / "set-appclip-invocation.py"
DEFAULT_METADATA = IOS_ROOT / "appstore-metadata.json"

APP_INFO_FIELDS = ("name", "subtitle")
VERSION_FIELDS = ("promotionalText", "keywords", "description")
SUPPORTED_PLATFORMS = {"IOS", "TV_OS"}
FIELD_LIMITS = {
    "name": 30,
    "subtitle": 30,
    "promotionalText": 170,
    "keywords": 100,
    "description": 4000,
}
RELEASED_APP_INFO_STATES = {
    "READY_FOR_DISTRIBUTION",
    "READY_FOR_SALE",
    "DEVELOPER_REMOVED_FROM_SALE",
    "REMOVED_FROM_SALE",
}

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
    try:
        text = (IOS_ROOT / "project.yml").read_text()
    except OSError:
        return None
    match = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)', text, re.M)
    return match.group(1) if match else None


def require_fields(value, expected, label):
    if not isinstance(value, dict):
        raise RuntimeError(f"{label} must be a JSON object")
    actual = set(value)
    expected = set(expected)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unknown:
            details.append("unknown " + ", ".join(unknown))
        raise RuntimeError(f"{label} has invalid fields: {'; '.join(details)}")


def load_metadata(path):
    try:
        metadata = json.loads(path.read_text())
    except OSError as error:
        raise RuntimeError(f"cannot read metadata file {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid JSON in {path}: {error}") from error

    require_fields(metadata, {"locale", "appInfo", "versions"}, str(path))
    locale = metadata["locale"]
    if not isinstance(locale, str) or not locale.strip():
        raise RuntimeError("locale must be a nonempty string")

    require_fields(metadata["appInfo"], APP_INFO_FIELDS, "appInfo")
    versions = metadata["versions"]
    if not isinstance(versions, dict) or not versions:
        raise RuntimeError("versions must be a nonempty JSON object")
    unsupported = sorted(set(versions) - SUPPORTED_PLATFORMS)
    if unsupported:
        raise RuntimeError("unsupported platforms: " + ", ".join(unsupported))
    for platform, fields in versions.items():
        require_fields(fields, VERSION_FIELDS, f"versions.{platform}")

    for section in [metadata["appInfo"], *versions.values()]:
        for field, value in section.items():
            if not isinstance(value, str) or not value.strip():
                raise RuntimeError(f"{field} must be a nonempty string")
            length = len(value.encode("utf-8")) if field == "keywords" else len(value)
            unit = "bytes" if field == "keywords" else "characters"
            if length > FIELD_LIMITS[field]:
                raise RuntimeError(
                    f"{field} is {length} {unit}; maximum is {FIELD_LIMITS[field]}"
                )
    keywords = [
        word.strip()
        for fields in versions.values()
        for word in fields["keywords"].split(",")
    ]
    if any(not word for word in keywords):
        raise RuntimeError("keywords must be a comma-separated list without empty entries")
    return metadata


def find_app(bundle_id):
    encoded = urllib.parse.quote(bundle_id, safe="")
    status, response = asc.call(
        "GET", f"/v1/apps?filter[bundleId]={encoded}&limit=10"
    )
    apps = expect(status, response, {200}, "finding the app").get("data", [])
    if len(apps) != 1:
        raise RuntimeError(
            f"expected one app with bundle id {bundle_id}, found {len(apps)}"
        )
    return apps[0]["id"]


def resource_state(resource):
    attributes = resource.get("attributes", {})
    return attributes.get("state") or attributes.get("appStoreState") or "UNKNOWN"


def find_app_info_localization(app_id, locale):
    status, response = asc.call("GET", f"/v1/apps/{app_id}/appInfos?limit=200")
    app_infos = expect(status, response, {200}, "listing app infos").get("data", [])
    candidates = []
    encoded_locale = urllib.parse.quote(locale, safe="")
    for app_info in app_infos:
        status, response = asc.call(
            "GET",
            f"/v1/appInfos/{app_info['id']}/appInfoLocalizations"
            f"?filter[locale]={encoded_locale}&limit=50",
        )
        localizations = expect(
            status, response, {200}, f"finding app info localization {locale}"
        ).get("data", [])
        if len(localizations) > 1:
            raise RuntimeError(
                f"app info {app_info['id']} has more than one {locale} localization"
            )
        if localizations:
            candidates.append((app_info, localizations[0]))

    if not candidates:
        raise RuntimeError(
            f"no app info localization exists for {locale}; create the locale in "
            "App Store Connect before running this scoped sync"
        )
    if len(candidates) == 1:
        return candidates[0][1]

    next_version = [
        item for item in candidates
        if resource_state(item[0]) not in RELEASED_APP_INFO_STATES
    ]
    if len(next_version) == 1:
        return next_version[0][1]
    states = ", ".join(
        f"{item[0]['id']}={resource_state(item[0])}" for item in candidates
    )
    raise RuntimeError(
        "cannot choose the next-version app info localization unambiguously; "
        f"found {states}"
    )


def find_version_localization(app_id, platform, version, locale):
    status, response = asc.call(
        "GET",
        f"/v1/apps/{app_id}/appStoreVersions?filter[platform]={platform}&limit=50",
    )
    versions = expect(
        status, response, {200}, f"listing {platform} versions"
    ).get("data", [])
    matches = [
        item for item in versions
        if item.get("attributes", {}).get("versionString") == version
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one {platform} version {version}, found {len(matches)}"
        )
    version_id = matches[0]["id"]
    encoded_locale = urllib.parse.quote(locale, safe="")
    status, response = asc.call(
        "GET",
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        f"?filter[locale]={encoded_locale}&limit=50",
    )
    localizations = expect(
        status, response, {200}, f"finding {platform} {locale} version localization"
    ).get("data", [])
    if len(localizations) != 1:
        raise RuntimeError(
            f"expected one {platform} {version} {locale} localization, "
            f"found {len(localizations)}"
        )
    return localizations[0]


def differences(resource, desired):
    attributes = resource.get("attributes", {})
    return {
        field: (attributes.get(field), value)
        for field, value in desired.items()
        if attributes.get(field) != value
    }


def print_differences(label, changes, prefix):
    for field, (current, desired) in changes.items():
        print(f"{prefix} {label} {field}")
        print(f"    current: {current!r}")
        print(f"    desired: {desired!r}")


def update_resource(resource_type, resource_id, attributes, label):
    body = {
        "data": {
            "type": resource_type,
            "id": resource_id,
            "attributes": attributes,
        }
    }
    status, response = asc.call(
        "PATCH", f"/v1/{resource_type}/{resource_id}", body
    )
    expect(status, response, {200}, f"updating {label}")


def read_resource(resource_type, resource_id, label):
    status, response = asc.call("GET", f"/v1/{resource_type}/{resource_id}")
    return expect(status, response, {200}, f"verifying {label}")["data"]


def sync_resource(resource_type, resource, desired, label, mode):
    changes = differences(resource, desired)
    if not changes:
        print(f"✓ {label}")
        return True
    if mode == "verify":
        print_differences(label, changes, "✗")
        return False
    if mode == "dry-run":
        print_differences(label, changes, "→ would set")
        return True

    changed_attributes = {field: desired[field] for field in changes}
    update_resource(resource_type, resource["id"], changed_attributes, label)
    refreshed = read_resource(resource_type, resource["id"], label)
    remaining = differences(refreshed, desired)
    if remaining:
        print_differences(label, remaining, "✗")
        raise RuntimeError(f"{label} still differs after update")
    print(f"✓ set and verified {label}")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default=asc.bundle_id_from_project())
    parser.add_argument("--version", default=project_version())
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="show drift without writes")
    mode.add_argument("--apply", action="store_true", help="apply drift (the default)")
    mode.add_argument(
        "--verify-only",
        action="store_true",
        help="fail unless App Store Connect exactly matches the canonical metadata",
    )
    args = parser.parse_args()

    if not args.bundle_id or not args.version:
        sys.exit("Bundle id and marketing version must be available or passed explicitly.")
    try:
        metadata = load_metadata(args.metadata)
        app_id = find_app(args.bundle_id)
        locale = metadata["locale"]
        app_info = find_app_info_localization(app_id, locale)
        version_localizations = {
            platform: find_version_localization(app_id, platform, args.version, locale)
            for platform in metadata["versions"]
        }

        selected_mode = (
            "verify" if args.verify_only else "dry-run" if args.dry_run else "apply"
        )
        matches = sync_resource(
            "appInfoLocalizations",
            app_info,
            metadata["appInfo"],
            f"app info {locale}",
            selected_mode,
        )
        for platform, desired in metadata["versions"].items():
            matches = sync_resource(
                "appStoreVersionLocalizations",
                version_localizations[platform],
                desired,
                f"{platform} {args.version} {locale} version metadata",
                selected_mode,
            ) and matches
        if selected_mode == "verify" and not matches:
            sys.exit(1)
    except RuntimeError as error:
        sys.exit(f"✗ {error}")


if __name__ == "__main__":
    main()
