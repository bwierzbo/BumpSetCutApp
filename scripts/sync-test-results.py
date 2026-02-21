#!/usr/bin/env python3
"""
Sync XCUITest results from .xcresult bundles to Supabase test dashboard.

Usage:
    python3 scripts/sync-test-results.py /path/to/Test.xcresult
    python3 scripts/sync-test-results.py  # auto-discover latest xcresult

Reads SUPABASE_URL and SUPABASE_ANON_KEY from environment, falling back to
../BumpSetCutWebApp/.env.local if present.
"""

import json
import os
import ssl
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

# --- Config ---

def _make_ssl_context():
    """Create an SSL context that works on macOS framework Python."""
    ctx = ssl.create_default_context()
    # macOS framework Python may lack certs — try system cert location
    for ca_path in ["/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"]:
        if os.path.exists(ca_path):
            ctx.load_verify_locations(ca_path)
            return ctx
    # Last resort: unverified (still better than crashing)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

_SSL_CTX = _make_ssl_context()

DEFAULT_SUPABASE_URL = "https://nodxhfrdefmaksisuylb.supabase.co"
DEFAULT_SUPABASE_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5vZHhoZnJkZWZtYWtzaXN1eWxiIiwi"
    "cm9sZSI6ImFub24iLCJpYXQiOjE3NzA0MTUzMTksImV4cCI6MjA4NTk5MTMxOX0."
    "mDkABYzOV3NJzgCeFbicUEkG7JTPGr2h_DvGfV8Fi9c"
)


def load_config():
    """Load Supabase URL and anon key from env or .env.local fallback."""
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_ANON_KEY")

    if not url or not key:
        env_path = Path(__file__).resolve().parent.parent.parent / "BumpSetCutWebApp" / ".env.local"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip("'\"")
                if k == "NEXT_PUBLIC_SUPABASE_URL" and not url:
                    url = v
                elif k == "NEXT_PUBLIC_SUPABASE_ANON_KEY" and not key:
                    key = v

    return url or DEFAULT_SUPABASE_URL, key or DEFAULT_SUPABASE_ANON_KEY


# --- xcresult extraction ---

def find_latest_xcresult():
    """Auto-discover the latest valid .xcresult in DerivedData."""
    derived = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    results = sorted(derived.rglob("*.xcresult"), key=lambda p: p.stat().st_mtime, reverse=True)

    def is_valid(p):
        return (p / "Info.plist").exists()

    # Prefer test results over launch/run results
    for r in results:
        if ("Test-" in r.name or "test" in r.name.lower()) and is_valid(r):
            return r
    for r in results:
        if is_valid(r):
            return r
    return None


def extract_results(xcresult_path):
    """Run xcresulttool and parse the JSON output."""
    cmd = [
        "xcrun", "xcresulttool", "get", "test-results", "tests",
        "--path", str(xcresult_path), "--compact"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error running xcresulttool: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("Error: xcrun not found. Ensure Xcode command line tools are installed.", file=sys.stderr)
        sys.exit(1)

    return json.loads(result.stdout)


def collect_test_cases(node, path_parts=None):
    """
    Recursively walk testNodes tree and collect test case results.
    Returns dict: {"ClassName/testMethodName": "Passed"|"Failed"|"Skipped"}
    """
    if path_parts is None:
        path_parts = []

    results = {}
    node_type = node.get("nodeType", "")
    name = node.get("name", "")

    if node_type == "Test Case":
        # Build identifier: last path part is the class, name is the method
        # Method name may have "()" suffix — strip it
        method = name.rstrip("()")
        if path_parts:
            class_name = path_parts[-1]
            identifier = f"{class_name}/{method}"
        else:
            identifier = method

        result = node.get("result", "unknown")
        results[identifier] = result
        return results

    # For non-leaf nodes, track Test Suite names as path context
    new_parts = list(path_parts)
    if node_type == "Test Suite":
        new_parts.append(name)

    for child in node.get("children", []):
        results.update(collect_test_cases(child, new_parts))

    return results


def parse_xcresult(data):
    """Parse top-level xcresult JSON into test identifier -> result map."""
    results = {}
    for node in data.get("testNodes", []):
        results.update(collect_test_cases(node))
    return results


# --- Supabase API ---

def supabase_request(url, key, method, path, body=None, params=None):
    """Make a Supabase REST API request."""
    full_url = f"{url}/rest/v1/{path}"
    if params:
        full_url += "?" + "&".join(f"{k}={v}" for k, v in params.items())

    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
    }

    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(full_url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, context=_SSL_CTX) as resp:
            if resp.status in (200, 201, 204):
                resp_data = resp.read().decode()
                return json.loads(resp_data) if resp_data else None
            return None
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"  Supabase API error ({e.code}): {error_body}", file=sys.stderr)
        return None


def fetch_mapped_items(url, key):
    """Fetch test_items that have automation_file set."""
    params = {
        "automation_file": "not.is.null",
        "select": "id,automation_file,status",
    }
    result = supabase_request(url, key, "GET", "test_items", params=params)
    return result or []


def update_item(url, key, item_id, status, now_iso):
    """Update a single test_item with new status."""
    # Map xcresult status to dashboard status
    status_map = {
        "Passed": "passed",
        "Failed": "failed",
        "Skipped": "skipped",
        "Expected Failure": "passed",  # expected failures are acceptable
        "unknown": "pending",
    }
    dashboard_status = status_map.get(status, "pending")

    body = {
        "status": dashboard_status,
        "updated_at": now_iso,
        "date_tested": now_iso,
        "updated_by": "XCUITest Automation",
    }

    params = {"id": f"eq.{item_id}"}
    supabase_request(url, key, "PATCH", "test_items", body=body, params=params)


# --- Main ---

def main():
    # Determine xcresult path
    if len(sys.argv) > 1:
        xcresult_path = Path(sys.argv[1])
        if not xcresult_path.exists():
            print(f"Error: {xcresult_path} does not exist", file=sys.stderr)
            sys.exit(1)
    else:
        xcresult_path = find_latest_xcresult()
        if not xcresult_path:
            print("Error: No .xcresult found in DerivedData. Pass path as argument.", file=sys.stderr)
            sys.exit(1)
        print(f"Auto-discovered: {xcresult_path}")

    # Extract and parse results
    print(f"Extracting results from {xcresult_path.name}...")
    raw = extract_results(xcresult_path)
    test_results = parse_xcresult(raw)

    if not test_results:
        print("No test cases found in xcresult.")
        sys.exit(0)

    print(f"Found {len(test_results)} test cases in xcresult\n")

    # Load config
    url, key = load_config()

    # Fetch mapped items from Supabase
    print("Fetching test_items with automation_file mappings...")
    items = fetch_mapped_items(url, key)
    if not items:
        print("No test_items with automation_file found in Supabase.")
        sys.exit(1)

    # Build reverse map: automation_file -> list of item IDs
    file_to_items = {}
    for item in items:
        af = item["automation_file"]
        if af not in file_to_items:
            file_to_items[af] = []
        file_to_items[af].append(item)

    print(f"Found {len(items)} mapped test_items across {len(file_to_items)} automation_file values\n")

    # Match and update
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    matched = 0
    updated_pass = 0
    updated_fail = 0
    updated_skip = 0
    unmapped_tests = []

    for test_id, result in sorted(test_results.items()):
        if test_id in file_to_items:
            for item in file_to_items[test_id]:
                update_item(url, key, item["id"], result, now)
                matched += 1
                if result == "Passed":
                    updated_pass += 1
                elif result == "Failed":
                    updated_fail += 1
                else:
                    updated_skip += 1
                print(f"  {result:8s} {test_id} -> item {item['id']}")
        else:
            unmapped_tests.append((test_id, result))

    # Summary
    print(f"\n{'='*50}")
    print(f"Sync complete: {matched} items updated")
    print(f"  Passed:  {updated_pass}")
    print(f"  Failed:  {updated_fail}")
    print(f"  Skipped: {updated_skip}")

    if unmapped_tests:
        print(f"\nUnmapped tests ({len(unmapped_tests)}):")
        for test_id, result in unmapped_tests:
            print(f"  {result:8s} {test_id}")


if __name__ == "__main__":
    main()
