#!/bin/bash
# Canonical build entry point for this repo. Replaces ad-hoc xcodebuild one-liners.
#
# Usage:
#   scripts/build.sh [ios|mac|both|auto] [--run]
#   scripts/build.sh doctor    # print the resolved simulator destination and exit
#   scripts/build.sh shared    # list modified files that are shared with RallyLab
#
#   auto (default) — inspect changed files (working tree, falling back to the
#     last commit) and build the affected targets: files in RallyLab's
#     membershipExceptions build BOTH; RallyLab/ files build mac; else ios.
#   --run — after a successful mac build, relaunch RallyLab.app from DerivedData.
#
# Simulator IDs rot when Xcode updates, so the destination is always resolved
# live from `simctl` (booted iPhone preferred). Full logs: /tmp/bsc-build-*.log

set -u
cd "$(dirname "$0")/.." || exit 1

PROJECT="BumpSetCut.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"

resolve_sim() {
  local booted udid
  booted=$(xcrun simctl list devices available | grep "iPhone" | grep "(Booted)" | head -1)
  udid=$(echo "${booted:-}" | grep -oE '[0-9A-F-]{36}')
  if [ -z "$udid" ]; then
    udid=$(xcrun simctl list devices available | grep "iPhone" | head -1 | grep -oE '[0-9A-F-]{36}')
  fi
  echo "$udid"
}

# Files the RallyLab target pulls in from the BumpSetCut/ folder (the shared pipeline).
shared_files() {
  awk '/Exceptions for "BumpSetCut" folder in "RallyLab" target \*\/ = \{/,/\);/' "$PBXPROJ" \
    | grep -v -E 'isa =|membershipExceptions|\);|\/\*' \
    | sed -e 's/^[[:space:]]*//' -e 's/,$//' -e 's/^"//' -e 's/"$//' \
    | grep -E '^[A-Za-z]' \
    | sed 's|^|BumpSetCut/|'
}

changed_files() {
  local changes
  changes=$(git status --porcelain | awk '{print $NF}')
  if [ -z "$changes" ]; then
    changes=$(git diff --name-only HEAD~1..HEAD 2>/dev/null)
  fi
  echo "$changes"
}

# run_build <scheme> <destination-args...>
run_build() {
  local scheme=$1; shift
  local log="/tmp/bsc-build-${scheme}.log"
  local attempt
  for attempt in 1 2; do
    xcodebuild -project "$PROJECT" -scheme "$scheme" "$@" build >"$log" 2>&1
    local status=$?
    if grep -q "unable to attach DB" "$log"; then
      if [ "$attempt" -eq 1 ]; then
        echo "⚠️  $scheme: build database locked (Xcode GUI is building) — retrying in 5s..."
        sleep 5
        continue
      fi
      echo "❌ $scheme: build database still locked. Stop the build in the Xcode GUI (or quit Xcode) and re-run."
      return 1
    fi
    grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" "$log" | grep -v "grep" | sort -u
    [ $status -ne 0 ] && echo "   full log: $log"
    return $status
  done
}

build_ios() {
  local udid
  udid=$(resolve_sim)
  if [ -z "$udid" ]; then
    echo "❌ No available iPhone simulator. Check: xcrun simctl list devices available"
    echo "   (If none exist, the iOS simulator runtime matching the SDK is missing — install it in Xcode ▸ Settings ▸ Components.)"
    return 1
  fi
  echo "▸ BumpSetCut (iOS sim $udid)"
  run_build BumpSetCut -destination "platform=iOS Simulator,id=$udid" CODE_SIGNING_ALLOWED=NO
}

build_mac() {
  echo "▸ RallyLab (macOS)"
  run_build RallyLab -destination "platform=macOS"
}

relaunch_rallylab() {
  local app
  app=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/BumpSetCut-*/Build/Products/Debug/RallyLab.app 2>/dev/null | head -1)
  if [ -z "$app" ]; then
    echo "❌ RallyLab.app not found in DerivedData"
    return 1
  fi
  pkill -x RallyLab 2>/dev/null
  sleep 1
  open "$app" && echo "✅ RallyLab relaunched"
}

MODE="${1:-auto}"
RUN_AFTER=0
[[ "${2:-}" == "--run" || "${1:-}" == "--run" ]] && RUN_AFTER=1
[[ "$MODE" == "--run" ]] && MODE="mac"

case "$MODE" in
  doctor)
    udid=$(resolve_sim)
    echo "simulator: ${udid:-NONE FOUND}"
    xcrun simctl list devices available | grep -E "iPhone" | grep -oE "iPhone [^(]+\($udid" 2>/dev/null
    exit 0 ;;
  shared)
    changed_files | grep -F -f <(shared_files)
    exit 0 ;;
  auto)
    changes=$(changed_files)
    # -F -f: substring match so files inside .mlpackage directories still count
    shared_hits=$(echo "$changes" | grep -F -f <(shared_files) || true)
    mac_hits=$(echo "$changes" | grep -c "^RallyLab/" || true)
    if [ -n "$shared_hits" ]; then
      echo "shared pipeline files changed → building BOTH targets:"
      echo "$shared_hits" | sed 's/^/  /'
      MODE=both
    elif [ "$mac_hits" -gt 0 ] && ! echo "$changes" | grep -q "^BumpSetCut/"; then
      MODE=mac
    else
      MODE=ios
    fi ;;
esac

FAILED=0
case "$MODE" in
  ios)  build_ios || FAILED=1 ;;
  mac)  build_mac || FAILED=1 ;;
  both) build_ios || FAILED=1; build_mac || FAILED=1 ;;
  *) echo "usage: scripts/build.sh [ios|mac|both|auto|doctor|shared] [--run]"; exit 2 ;;
esac

if [ "$FAILED" -eq 0 ] && [ "$RUN_AFTER" -eq 1 ] && [[ "$MODE" == "mac" || "$MODE" == "both" ]]; then
  relaunch_rallylab
fi
exit $FAILED
