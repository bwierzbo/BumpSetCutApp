---
name: preexisting
description: Determine whether a failing test is a pre-existing failure or a regression from current changes. Use whenever a test fails after making changes in this repo. The unit suite was fully green on 2026-10-04 (377/377), so a failure is most likely new — this check confirms it before debugging.
---

# Is this test failure pre-existing?

The unit suite was fully green on 2026-10-04 (377 tests, 0 failures) — the old "~91 failing" baseline was fixed or removed. A failure is therefore most likely caused by the current changes, but check before debugging (a flaky or environment-dependent test can still fail on a clean tree):

1. Note the exact failing test identifier(s), e.g. `BumpSetCutTests/SegmentBuilderTests/testSegmentAtEndOfVideoGetsClamped`.
2. Stash the working tree and re-run ONLY those tests on the clean checkout:

```bash
git stash push -u -m "preexisting-check"
UDID=$(scripts/build.sh doctor | sed -n 's/^simulator: //p')
xcodebuild test -project BumpSetCut.xcodeproj -scheme BumpSetCut \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:BumpSetCutTests/<SuiteName>/<testName> 2>&1 \
  | grep -E "Test Case|error:|passed|failed" | tail -20
git stash pop
```

3. Verdict:
   - **Fails on clean tree** → pre-existing. Report it as such and move on; do not fix unless asked. If it's clearly OBE (tests an approach that no longer exists), the user has authorized deleting OBE tests — propose deletion.
   - **Passes on clean tree** → regression from the current changes. Debug it.

Always `git stash pop` even if the test run errors — never leave the user's changes stashed.
