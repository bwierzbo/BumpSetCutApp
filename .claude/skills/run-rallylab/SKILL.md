---
name: run-rallylab
description: Build the RallyLab macOS target and relaunch the app in one step. Use whenever RallyLab needs rebuilding and relaunching to test pipeline/labeling changes (replaces the manual build → pkill → open-DerivedData loop).
---

# Build & relaunch RallyLab

```bash
scripts/build.sh mac --run
```

That's the whole loop: builds the RallyLab scheme (errors-only output), then `pkill -x RallyLab` and reopens the app from DerivedData.

## Notes

- If the build fails, the app is NOT relaunched — fix errors and re-run.
- If the change also touched shared pipeline files (files in RallyLab's `membershipExceptions`), verify the iOS target too: `scripts/build.sh both` then relaunch with `scripts/build.sh mac --run` (already-built = fast no-op rebuild).
- Exit codes 144/149 from a bare `open`/`pkill` sequence were a recurring nuisance — the script sleeps between kill and open to avoid the "Unable to lookup in current state: Shutdown" race. Don't reintroduce manual pkill/open one-liners.
