---
name: hybrid-mac-windows-plan
status: proposed
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
decision: D-003
---

# Hybrid Mac/Windows workflow — implementation plan

Decision [D-003](../decisions/DECISION_LOG.md#d-003): the Windows desktop is the canonical store for source footage and the primary GPU trainer; the Mac runs RallyLab, Core ML verification, annotation review and Apple-platform testing. This is a **plan**. Each step marked **[owner authorisation]** installs software or changes a network/security setting and is not executed until the owner says so for that step.

## What was verified (read-only, 2026-10-20)

Probed over the existing LAN SSH host `bsc-desktop` (`bens-desktop.local`, user `bwier`, key `~/.ssh/bsc_desktop`):

| Item | Desktop (Windows) | Mac |
|---|---|---|
| OS | Windows 11 **Home** 10.0.26200 | macOS 26.4 |
| OpenSSH server | `sshd` **running, Automatic**; OpenSSH_for_Windows 9.5p2; `administrators_authorized_keys` present (key auth already works) | n/a (client) |
| ssh-agent | stopped/disabled (not needed) | — |
| Remote Desktop (RDP) | `TermService` stopped; connections denied; **Home edition cannot host RDP** | — |
| Tailscale | **not installed** | `Tailscale.app` + `/usr/local/bin/tailscale` installed (login state not checked) |
| Account | `bens-desktop\bwier`, local administrator | — |
| Network profile | Private | — |
| Footage | `D:\RallyLabFootage\Scratch\footage` present | Scratch project at `~/Movies/RallyLab/Projects/Scratch` (footage absent) |

Source for Tailscale facts: [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) — "Tailscale SSH's server component is only available on Linux and macOS"; [Install on Windows](https://tailscale.com/kb/1022/install-windows) — Windows 10+ supported, `.exe` or MSI installer, authenticate via identity provider; [ACLs](https://tailscale.com/kb/1018/acls) — deny-by-default, per-port `dst` rules, locally enforced.

## Design

```
Mac (RallyLab, Core ML, review)  ──tailnet──▶  Windows desktop (footage, GPU)
   ssh bsc-desktop  (OpenSSH over Tailscale, key-only)      sshd (already running)
   scp/rsync + manifest.json (SHA-256)                      D:\RallyLabFootage\<project>\footage
   remote desktop client ──────────────────▶                remote-desktop host (choice below)
```

- **Automation:** standard OpenSSH over the tailnet. Tailscale SSH is not used (no Windows server). The existing `desktop.sh train|queue|status|fetch` keeps working; only the host address changes from `bens-desktop.local` to the Tailscale name/IP (MagicDNS).
- **Interactive access:** RDP is unavailable on Home. Options, to be chosen by the owner: (a) Chrome Remote Desktop (free, works over any network, Google account), (b) Parsec (low-latency, free personal tier), (c) RustDesk self-hosted or direct over the tailnet (open source, no third party), (d) upgrade the desktop to Windows 11 Pro (paid) and use RDP over Tailscale. Recommendation: (c) RustDesk in direct-IP mode over the tailnet keeps everything inside the private network; (a) if simplicity matters more.
- **Exposure:** no public port forwarding. Windows firewall keeps `sshd` (22) and the remote-desktop port open on the Private profile only; Tailscale traffic arrives on the `tailscale0` interface. Tailscale ACL restricts 22 and the remote-desktop port to the owner's devices.
- **One annotation store:** the Mac RallyLab project is the only editable copy of sessions, rally marks and ball paths. The desktop holds footage, training packages, checkpoints and run outputs. Nothing on the desktop edits `sessions/*.json` or `*.rallylabels.json`; anything labelled on the Labeler iPhone syncs through Supabase to the Mac as today.

## Steps

| # | Step | Where | Gate |
|---|---|---|---|
| 1 | Install Tailscale from the official installer; sign in with the owner's identity provider | Windows | **[owner authorisation]** |
| 2 | Enable "Run unattended" so the node stays connected with no user logged in (System tray → Preferences → Run unattended) | Windows | **[owner authorisation]** |
| 3 | Confirm the Mac Tailscale client is signed in to the same tailnet | Mac | owner |
| 4 | Enable MagicDNS; note the desktop's tailnet name (e.g. `bens-desktop.<tailnet>.ts.net`) | Tailscale admin console | **[owner authorisation]** |
| 5 | Set key expiry policy for both nodes (disable expiry on the desktop, or accept periodic re-auth) | admin console | **[owner authorisation]** |
| 6 | ACL: deny-by-default; allow the owner's user to the desktop on 22 and the remote-desktop port only; tag the desktop `tag:gpu` | admin console | **[owner authorisation]** — draft below |
| 7 | Confirm Windows firewall rules for `sshd` apply to Private only and that Tailscale's interface is treated as Private | Windows | **[owner authorisation]** if a change is needed |
| 8 | Add a second `Host bsc-desktop-ts` entry in `~/.ssh/config` pointing at the tailnet name, same key; keep `bsc-desktop` for LAN | Mac | implementer (no security change) |
| 9 | Verify `ssh bsc-desktop-ts 'hostname'` from the Mac off-LAN; verify `desktop.sh status` | Mac | implementer |
| 10 | Install and configure the chosen remote-desktop host; bind to tailnet only where the tool allows | Windows | **[owner authorisation]** |
| 11 | Document the final configuration here (versions, tailnet names, ACL as applied) and update `desktop.sh` defaults | repo | PR |

Draft ACL (adjust names to the real tailnet; the owner applies it):

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:gpu:22", "tag:gpu:21118"] }
  ]
}
```

(`21118` is RustDesk's default direct port; replace with the chosen tool's port, or `3389` if RDP becomes available.)

## Footage and artefact transfer

Versioned, checksummed, one direction at a time.

- **Footage manifest.** `D:\RallyLabFootage\<project>\footage\manifest.json`: for every file, relative path, size, SHA-256, `addedAt`, `sourceId` (from `project.json`). Generated on the desktop (`Get-FileHash -Algorithm SHA256`) and committed to the repo under `docs/ml-roadmap/manifests/<project>-footage-<date>.json` so every evaluation can name the exact footage version by its hash.
- **Pull to the Mac** for evaluation that needs video: `rsync -av --files-from=<list> bsc-desktop-ts:/d/RallyLabFootage/<project>/footage/ ~/Movies/RallyLab/Projects/<project>/footage/` (rsync over the Windows OpenSSH shell needs rsync on Windows — cwRsync or Git for Windows' rsync; otherwise `scp -r`), then `shasum -a 256 -c` against the manifest before use. Copies on the Mac are transient and are deleted after the evaluation unless the owner says otherwise.
- **Push to the desktop** (training packages, val exports): `desktop.sh train` already copies the package; add a SHA-256 check on arrival and record the hash in the experiment record.
- **Fetch results** (checkpoints, metrics.json, log.csv): `desktop.sh fetch NAME --no-score`, hash on arrival, register in the [experiment registry](../ml-roadmap/EXPERIMENT_REGISTRY.md).
- **Never** two editable copies of annotations. If the desktop needs rally marks (e.g. to build dead windows), it receives an export with a hash, read-only.

## Open items for the owner

1. Choice of remote-desktop tool (a–d above).
2. Authorisation for steps 1, 2, 4, 5, 6, 7, 10 individually or as a batch.
3. Whether the desktop's Tailscale node should have key expiry disabled (convenience) or periodic re-authentication (stricter).
4. Whether footage pulled to the Mac may persist between evaluations (disk: 25 GB for Scratch).
