---
name: l2-run4-undecodable-frames-direction
status: accepted
created: 2026-10-24T17:36:41Z
updated: 2026-10-24T17:36:41Z
source: owner, delivered to Claude Code on 2026-10-24 after the fourth resumed L2 export stopped on an undecodable HEVC frame
---

> Verbatim record of the owner's direction after the fourth resumed L2 export (`Scratch-L2-multiframe-20261021-1917`, run 4, started 2026-10-24T02:49Z from main `6f73cec`) stopped at 11:02Z on `bch_ele_sun_land_self_01/1685000.jpg` (`Cannot Decode`): an HEVC leading picture the frame-accurate decoder cannot produce. Primary source for D-024 (amending D-022). Reproduced as received; the heading is the owner's.

# L2 Run 4 — Owner Direction

I select **Option 1: explicitly record confirmed undecodable HEVC frames and exclude affected temporal windows**.

I do not want to discard the three recordings or repeat the existing validated-frame work unnecessarily.

Proceed with preparing the focused corrective PR, subject to these requirements:

1. Reconcile the frame counts before requesting merge or resume authorization. The previous corrected plan was 81,295 frames, but the latest report shows 54,183 already present plus 48,884 remaining, implying 103,067. Explain the difference and provide the authoritative current plan.

2. Implement a narrow, evidence-backed exception for reproducibly undecodable HEVC leading pictures. Do not turn general decoder failures into accepted omissions.

3. Journal every excluded frame with its clip, timestamp, error, and reason.

4. Exclude any complete nine-frame window requiring that frame. Do not duplicate neighboring frames, interpolate targets, or assign no-ball labels to undecodable footage.

5. Preserve the existing 54,183 frames, subject to normal integrity validation. Preserve journal identity protections and explain why resuming under the new exclusion policy is safe.

6. Report exact frame and window exclusions by clip and split, including the effect on human-reviewed training targets and validation coverage.

7. Add regression tests using the synthetic open-GOP HEVC fixture, including tests proving unrelated failures remain fatal.

8. Update D-022 through a controlled amendment, the preregistration, and experiment registry. Keep the original decision history intact.

9. Run the required tests, obtain Codex review, and return the PR with findings and corrected counts.

**This authorizes preparation of Option 1, not its merge or export restart.** Return the reviewed PR and reconciled counts for my authorization.

L2 training, protected-holdout evaluation, model promotion, and unrelated dataset changes remain unauthorized.
