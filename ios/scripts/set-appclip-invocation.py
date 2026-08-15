#!/usr/bin/env python3
"""Register the App Clip's TestFlight invocation URL for a build.

App Store Connect scopes App Clip invocations to a *build*, so every upload
otherwise needs the same three fields re-entered by hand before the clip can be
launched from TestFlight. This does it through the API instead.

    ZW_APPCLIP_INVOCATION_URL=https://api.example.com/app/g \
      ios/scripts/set-appclip-invocation.py                   # newest build
    ios/scripts/set-appclip-invocation.py --url https://api.example.com/app/g
    ios/scripts/set-appclip-invocation.py --url 'https://api.example.com/app/g#zwg_…'

The bundle id is read from the gitignored ios/project.yml; the URL has no
default, because a real one would be an identifier this repository keeps out.

Credentials come from the same place as the upload script:
~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 and ~/.appstoreconnect/issuer_id,
overridable with ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID.

Requires an API key whose role permits writing TestFlight metadata. A key that
can only read will report that plainly rather than appearing to succeed.
"""
import argparse, base64, glob, json, os, re, subprocess, sys, time, urllib.error, urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64u(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def der_to_raw(der: bytes) -> bytes:
    """ASN.1 SEQUENCE{INTEGER r, INTEGER s} -> the fixed 32-byte r||s JWS wants."""
    i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    out = b""
    for _ in range(2):
        ln = der[i + 1]
        out += der[i + 2:i + 2 + ln].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + ln
    return out


def token() -> str:
    key_path = os.environ.get("ASC_KEY_PATH") or next(
        iter(sorted(glob.glob(os.path.expanduser(
            "~/.appstoreconnect/private_keys/AuthKey_*.p8")),
            key=os.path.getmtime, reverse=True)), None)
    if not key_path or not os.path.exists(key_path):
        sys.exit("No App Store Connect key found (see ~/.appstoreconnect/private_keys).")
    kid = os.environ.get("ASC_KEY_ID") or os.path.basename(key_path)[len("AuthKey_"):-len(".p8")]
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not issuer:
        p = os.path.expanduser("~/.appstoreconnect/issuer_id")
        if not os.path.exists(p):
            sys.exit("No issuer id (see ~/.appstoreconnect/issuer_id).")
        issuer = open(p).read().strip()
    now = int(time.time())
    header = b64u(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    payload = b64u(json.dumps(
        {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = header + b"." + payload
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input, capture_output=True, check=True).stdout
    return (signing_input + b"." + b64u(der_to_raw(der))).decode()


def call(method: str, path: str, body=None):
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
        method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, (json.load(r) if r.status != 204 else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw}


def die_on_permission(status, body, what):
    if status == 403:
        detail = ""
        if isinstance(body, dict):
            detail = "; ".join(e.get("detail", "") for e in body.get("errors", []))
        print(f"✗ {what}: App Store Connect refused this key.")
        print(f"  {detail}")
        print("  App Store Connect API key roles are fixed when the key is created, so this")
        print("  needs a new key with a role permitting TestFlight metadata writes")
        print("  (Users and Access -> Integrations). Until then, set the invocation by hand")
        print("  on the build under TestFlight -> App Clip Invocations.")
        sys.exit(2)


def bundle_id_from_project():
    """Read the app's bundle id from the gitignored ios/project.yml.

    Nothing identifying is hardcoded here for the same reason the rest of this
    repository avoids it: it is meant to be public. The first
    PRODUCT_BUNDLE_IDENTIFIER in project.yml is the app target's.
    """
    path = os.path.join(os.path.dirname(__file__), "..", "project.yml")
    try:
        text = open(path).read()
    except OSError:
        return None
    match = re.search(r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", text, re.M)
    return match.group(1) if match else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", default=os.environ.get("ZW_BUNDLE_ID") or bundle_id_from_project())
    ap.add_argument("--url", default=os.environ.get("ZW_APPCLIP_INVOCATION_URL"))
    ap.add_argument("--title", default="00Widget")
    ap.add_argument("--build", help="build number; default is the newest")
    ap.add_argument("--wait", type=int, default=900,
                    help="seconds to wait for the build to finish processing")
    args = ap.parse_args()
    if not args.bundle_id:
        sys.exit("No bundle id: pass --bundle-id, set ZW_BUNDLE_ID, or create ios/project.yml.")
    if not args.url:
        sys.exit(
            "No invocation URL: pass --url or set ZW_APPCLIP_INVOCATION_URL.\n"
            "  It is the App Clip's registered URL, e.g. https://<your-host>/app/g\n"
            "  Append '#<guest token>' to point a build at a specific shared link.")

    status, apps = call("GET", "/v1/apps?limit=200")
    die_on_permission(status, apps, "listing apps")
    match = [a for a in apps.get("data", []) if a["attributes"]["bundleId"] == args.bundle_id]
    if not match:
        sys.exit(f"No app with bundle id {args.bundle_id}")
    app_id = match[0]["id"]

    # A build's bundles only exist once processing finishes, which is why this
    # cannot simply run inline with the upload.
    deadline = time.time() + args.wait
    build = None
    while True:
        status, builds = call("GET", f"/v1/builds?filter[app]={app_id}&limit=10&sort=-version")
        die_on_permission(status, builds, "listing builds")
        data = builds.get("data", [])
        if args.build:
            data = [b for b in data if b["attributes"]["version"] == args.build]
        if data:
            build = data[0]
            state = build["attributes"].get("processingState")
            if state == "VALID":
                break
            if state in ("INVALID", "FAILED"):
                sys.exit(f"Build {build['attributes']['version']} is {state}")
            print(f"  build {build['attributes']['version']} is {state}; waiting…")
        if time.time() > deadline:
            sys.exit("Timed out waiting for the build to finish processing.")
        time.sleep(30)

    version = build["attributes"]["version"]
    status, detail = call("GET", f"/v1/builds/{build['id']}?include=buildBundles")
    die_on_permission(status, detail, "reading build bundles")
    clips = [b for b in detail.get("included", [])
             if b.get("attributes", {}).get("bundleType") == "APP_CLIP"]
    if not clips:
        print(f"Build {version} contains no App Clip; nothing to do.")
        return
    clip_id = clips[0]["id"]

    status, existing = call(
        "GET", f"/v1/buildBundles/{clip_id}/betaAppClipInvocations")
    die_on_permission(status, existing, "reading existing invocations")
    for inv in existing.get("data", []):
        if inv["attributes"].get("url") == args.url:
            print(f"✓ build {version} already invokes {args.url}")
            return

    payload = {
        "data": {
            "type": "betaAppClipInvocations",
            "attributes": {"url": args.url},
            "relationships": {
                "buildBundle": {"data": {"type": "buildBundles", "id": clip_id}},
                "betaAppClipInvocationLocalizations": {
                    "data": [{"type": "betaAppClipInvocationLocalizations", "id": "${loc}"}]
                },
            },
        },
        "included": [{
            "type": "betaAppClipInvocationLocalizations",
            "id": "${loc}",
            "attributes": {"locale": "en-US", "title": args.title},
        }],
    }
    status, created = call("POST", "/v1/betaAppClipInvocations", payload)
    die_on_permission(status, created, "creating the invocation")
    if status not in (200, 201):
        sys.exit(f"Unexpected response {status}: {json.dumps(created)[:400]}")
    print(f"✓ build {version} now invokes {args.url}")


if __name__ == "__main__":
    main()
