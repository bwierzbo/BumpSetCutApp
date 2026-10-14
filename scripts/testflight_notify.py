#!/usr/bin/env python3
"""TestFlight emails only when you ask: turn a build's automatic "new build"
notification off, or send it yourself.

  testflight_notify.py quiet  APP_ID BUILD   wait for the build to show up in
                                             App Store Connect, then switch its
                                             automatic notification off
  testflight_notify.py notify APP_ID BUILD   email/notify its testers now
  testflight_notify.py status APP_ID         the latest builds and their setting

APP_ID: 6820196175 RallyLab, 6759111528 BumpSetCut. Uses asc_feedback.py's
API key (run with ~/.venvs/asc/bin/python — the Mac's python3 is broken).
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request

import asc_feedback as a


def send(method: str, path: str, body: dict) -> dict:
    req = urllib.request.Request(f"{a.API}{path}", data=json.dumps(body).encode(), method=method,
                                 headers={"Authorization": f"Bearer {a.token()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=a.SSL_CONTEXT) as resp:
        return json.load(resp)


def build(app: str, number: str, wait: bool) -> dict | None:
    for _ in range(60 if wait else 1):
        found = a.get("/v1/builds", f"filter[app]={app}&filter[version]={number}&include=buildBetaDetail").get("included") or []
        if found:
            return found[0]
        if wait:
            time.sleep(15)
    return None


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    action, app = sys.argv[1], sys.argv[2]
    if action == "status":
        builds = a.get("/v1/builds", f"filter[app]={app}&sort=-uploadedDate&limit=5&include=buildBetaDetail")
        details = {d["id"]: d["attributes"] for d in builds.get("included", [])}
        for b in builds["data"]:
            d = details.get(b["relationships"]["buildBetaDetail"]["data"]["id"], {})
            print(f"{b['attributes']['version']}  {b['attributes']['processingState']:<11}  auto-notify {d.get('autoNotifyEnabled')}")
        return
    number = sys.argv[3]
    detail = build(app, number, wait=action == "quiet")
    if detail is None:
        sys.exit(f"❌ Build {number} isn't in App Store Connect yet.")
    if action == "quiet":
        send("PATCH", f"/v1/buildBetaDetails/{detail['id']}",
             {"data": {"type": "buildBetaDetails", "id": detail["id"], "attributes": {"autoNotifyEnabled": False}}})
        print(f"🔕 Build {number}: testers won't be notified automatically.")
    elif action == "notify":
        build_id = a.get("/v1/builds", f"filter[app]={app}&filter[version]={number}")["data"][0]["id"]
        send("POST", "/v1/buildBetaNotifications",
             {"data": {"type": "buildBetaNotifications", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print(f"📣 Build {number}: testers notified.")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
