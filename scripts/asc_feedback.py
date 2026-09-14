#!/usr/bin/env python3
"""Fetch TestFlight beta feedback (screenshots + crashes) from the
App Store Connect API.

Auth: reads the team API key from ~/.appstoreconnect/private_keys/
(AuthKey_<KEY_ID>.p8 — never stored in the repo).

Usage:
  scripts/asc_feedback.py                 # list screenshot feedback + crashes
  scripts/asc_feedback.py --since 2026-09-14
  scripts/asc_feedback.py --download DIR  # also save screenshot images to DIR
"""

import argparse
import json
import pathlib
import ssl
import sys
import time
import urllib.request

import certifi
import jwt

SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

KEY_ID = "64N92V67FL"
ISSUER_ID = "a42b4a1a-499c-4fd6-9a42-a2971d9669b9"
APP_ID = "6759111528"  # BumpSetCut
API = "https://api.appstoreconnect.apple.com"


def token() -> str:
    key_path = pathlib.Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{KEY_ID}.p8"
    private_key = key_path.read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def get(path: str, params: str = "") -> dict:
    url = f"{API}{path}{'?' + params if params else ''}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req, context=SSL_CONTEXT) as resp:
        return json.load(resp)


def fmt_device(attrs: dict) -> str:
    return f"{attrs.get('deviceModel', '?')} iOS {attrs.get('osVersion', '?')}"


def show_screenshot_feedback(since: str | None, download_dir: pathlib.Path | None) -> None:
    params = (
        "sort=-createdDate&limit=50"
        "&include=build,tester"
        "&fields[betaTesters]=firstName,lastName,email"
        "&fields[builds]=version"
    )
    data = get(f"/v1/apps/{APP_ID}/betaFeedbackScreenshotSubmissions", params)
    included = {(i["type"], i["id"]): i for i in data.get("included", [])}

    items = data.get("data", [])
    if since:
        items = [i for i in items if i["attributes"].get("createdDate", "") >= since]

    print(f"=== Screenshot feedback ({len(items)}) ===")
    for item in items:
        attrs = item["attributes"]
        rel = item.get("relationships", {})

        tester = ""
        tester_ref = (rel.get("tester") or {}).get("data")
        if tester_ref:
            t = included.get((tester_ref["type"], tester_ref["id"]), {}).get("attributes", {})
            tester = f"{t.get('firstName', '')} {t.get('lastName', '')} <{t.get('email', '')}>".strip()

        build = ""
        build_ref = (rel.get("build") or {}).get("data")
        if build_ref:
            b = included.get((build_ref["type"], build_ref["id"]), {}).get("attributes", {})
            build = b.get("version", "")

        print(f"\n[{attrs.get('createdDate', '')}] {tester} — build {build} — {fmt_device(attrs)}")
        print(f"  {attrs.get('comment', '(no comment)')}")

        if download_dir:
            download_dir.mkdir(parents=True, exist_ok=True)
            for n, shot in enumerate(attrs.get("screenshots") or []):
                url = shot.get("url")
                if not url:
                    continue
                out = download_dir / f"{item['id']}_{n}.png"
                with urllib.request.urlopen(urllib.request.Request(url), context=SSL_CONTEXT) as r, open(out, "wb") as f:
                    f.write(r.read())
                print(f"  screenshot -> {out}")


def show_crashes(since: str | None) -> None:
    params = (
        "sort=-createdDate&limit=50"
        "&include=build,tester"
        "&fields[betaTesters]=firstName,lastName,email"
        "&fields[builds]=version"
    )
    data = get(f"/v1/apps/{APP_ID}/betaFeedbackCrashSubmissions", params)
    included = {(i["type"], i["id"]): i for i in data.get("included", [])}

    items = data.get("data", [])
    if since:
        items = [i for i in items if i["attributes"].get("createdDate", "") >= since]

    print(f"\n=== Crash feedback ({len(items)}) ===")
    for item in items:
        attrs = item["attributes"]
        rel = item.get("relationships", {})

        tester = ""
        tester_ref = (rel.get("tester") or {}).get("data")
        if tester_ref:
            t = included.get((tester_ref["type"], tester_ref["id"]), {}).get("attributes", {})
            tester = f"{t.get('firstName', '')} {t.get('lastName', '')}".strip()

        build = ""
        build_ref = (rel.get("build") or {}).get("data")
        if build_ref:
            b = included.get((build_ref["type"], build_ref["id"]), {}).get("attributes", {})
            build = b.get("version", "")

        print(f"\n[{attrs.get('createdDate', '')}] {tester} — build {build} — {fmt_device(attrs)}")
        print(f"  {attrs.get('comment', '(no comment)')}")
        print(f"  crash log id: {item['id']} (fetch via /v1/betaFeedbackCrashSubmissions/{item['id']}/crashLog)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--since", help="ISO date, e.g. 2026-09-14")
    parser.add_argument("--download", help="directory to save screenshot images")
    args = parser.parse_args()

    download_dir = pathlib.Path(args.download) if args.download else None
    try:
        show_screenshot_feedback(args.since, download_dir)
        show_crashes(args.since)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
