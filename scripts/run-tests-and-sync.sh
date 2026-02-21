#!/bin/bash
# Run XCUITests and sync results to Supabase test dashboard.
#
# Usage:
#   ./scripts/run-tests-and-sync.sh                    # Run all UI tests
#   ./scripts/run-tests-and-sync.sh LaunchTests         # Run specific test class
#   ./scripts/run-tests-and-sync.sh --sync-only PATH    # Skip tests, just sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULT_PATH="/tmp/BumpSetCut-test-results.xcresult"

# Auto-detect simulator: prefer iOS 26.2 iPhone, fall back to any available
DESTINATION=""
detect_simulator() {
    # Try iPhone 17 Pro on iOS 26.2 (matches UI test deployment target)
    local sim_id
    sim_id=$(xcrun simctl list devices available 2>/dev/null \
        | sed -n '/-- iOS 26.2 --/,/^--/p' \
        | grep "iPhone 17 Pro " \
        | grep -oE '[A-F0-9-]{36}' \
        | head -1)

    if [ -n "$sim_id" ]; then
        DESTINATION="platform=iOS Simulator,id=$sim_id"
        return
    fi

    # Fall back to any iPhone on iOS 26.2
    sim_id=$(xcrun simctl list devices available 2>/dev/null \
        | sed -n '/-- iOS 26.2 --/,/^--/p' \
        | grep "iPhone" \
        | grep -oE '[A-F0-9-]{36}' \
        | head -1)

    if [ -n "$sim_id" ]; then
        DESTINATION="platform=iOS Simulator,id=$sim_id"
        return
    fi

    # Last resort: any iPhone simulator
    sim_id=$(xcrun simctl list devices available 2>/dev/null \
        | grep "iPhone" \
        | grep -oE '[A-F0-9-]{36}' \
        | head -1)

    if [ -n "$sim_id" ]; then
        DESTINATION="platform=iOS Simulator,id=$sim_id"
        return
    fi

    echo "Error: No iPhone simulator found"
    exit 1
}

# Sync-only mode
if [ "${1:-}" = "--sync-only" ]; then
    SYNC_PATH="${2:-}"
    if [ -z "$SYNC_PATH" ]; then
        echo "Syncing from latest xcresult..."
        python3 "$SCRIPT_DIR/sync-test-results.py"
    else
        python3 "$SCRIPT_DIR/sync-test-results.py" "$SYNC_PATH"
    fi
    exit $?
fi

# Find project file
PROJECT_FILE="$PROJECT_DIR/BumpSetCut.xcodeproj"
if [ ! -d "$PROJECT_FILE" ]; then
    echo "Error: $PROJECT_FILE not found"
    exit 1
fi

detect_simulator
echo "Using simulator: $DESTINATION"

# Build test filter
TEST_FILTER=""
if [ -n "${1:-}" ]; then
    TEST_FILTER="-only-testing:BumpSetCutUITests/$1"
    echo "Running: $1"
else
    echo "Running: All UI tests"
fi

# Clean previous result bundle
rm -rf "$RESULT_PATH"

# Run tests
echo "Building and running tests..."
# shellcheck disable=SC2086
xcodebuild -project "$PROJECT_FILE" \
    -scheme BumpSetCut \
    -destination "$DESTINATION" \
    $TEST_FILTER \
    test \
    -resultBundlePath "$RESULT_PATH" 2>&1 | tail -20

echo ""

# Sync results
if [ -d "$RESULT_PATH" ]; then
    python3 "$SCRIPT_DIR/sync-test-results.py" "$RESULT_PATH"
else
    echo "Warning: No xcresult bundle produced at $RESULT_PATH"
    echo "Tests may have failed to build."
    exit 1
fi
