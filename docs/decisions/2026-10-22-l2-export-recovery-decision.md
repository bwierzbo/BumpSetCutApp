---
name: l2-export-recovery-decision
status: accepted
created: 2026-10-22T14:15:08Z
updated: 2026-10-22T14:15:08Z
source: owner, delivered to Claude Code on 2026-10-22
---

> Verbatim record of the owner's decisions after the first L2 export (`Scratch-L2-multiframe-20261021-1917`, started 2026-10-21) failed at 10:50 UTC on 2026-10-22 when the SMB sessions to the desktop dropped (the desktop's Wi‑Fi retired the IPv6 privacy address Tailscale's direct path was using). Normalised as [D-022](DECISION_LOG.md#d-022). This file is the primary source; do not edit it.

Owner decisions — L2 export recovery

**Approve Option 1 + Option 2. Preserve the partial package.**

### Network recovery

Use direct LAN SMB to the desktop at `10.0.0.123`, provided both machines are on the same trusted LAN.

- Restrict SMB firewall access to the Mac's specific LAN IP.
- Prefer stable DHCP reservations.
- Preserve read-only access to the original footage.
- Preserve separate writable access to export staging.
- Do not disable IPv6 privacy addresses globally.
- Do not expose SMB to the public internet or store credentials in scripts, Git or logs.

Verify both mounts and sustained read/write access before resuming.

### Resumable export

Implement resumability in a focused RallyLab PR with tests and independent Codex review.

Requirements:
- Reuse the existing partial export only when each retained frame is validated against the expected source, timestamp, format and completeness criteria.
- Do not assume a file is valid merely because it exists.
- Handle corrupt or incomplete files safely.
- Detect lost mounts and fail promptly.
- Retry transient I/O errors with bounded retries.
- Never silently skip source videos or expected frames.
- Generate the final windows, summary and package manifest only when export completion is verified.
- Run the full normal preflight, source-identity, split-isolation and protected-content checks afterward.
- Require successful desktop package verification before presenting the package for training approval.

Keep the partial folder:
`D:\RallyLabStaging\Scratch-exports\Scratch-L2-multiframe-20261021-1917`

No deletion or wholesale replacement is authorized.

### Existing PR approvals

**Merge PR #83**, after correcting its title from D-020 to D-021. Its owner-controlled configuration changes remain approved.

**Merge PR #84 after #83**, with its D-007 amendment and CI-BSC-001, CI-BSC-010, CI-BSC-053 and CF-BSC-006 changes explicitly approved. Rebase and rerun applicable checks.

### Execution gate

Do not start the replacement export until the LAN connection is verified and the resumability implementation has passed review and received merge authorization.

Once the reviewed fixes are merged, return with the exact resume command and validation results before rerunning.

No L2 training or protected-holdout evaluation is authorized.
