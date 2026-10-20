---
name: hybrid-mac-windows-plan
status: connection verified; transfer workflow and remote desktop pending
created: 2026-10-20T22:12:44Z
updated: 2026-10-21T00:05:00Z
decision: D-003
---

# Hybrid Mac/Windows workflow — implementation plan

Decision [D-003](../decisions/DECISION_LOG.md#d-003): the Windows desktop is the canonical store for source footage and the primary GPU trainer; the Mac runs RallyLab, Core ML verification, annotation review and Apple-platform testing. Steps marked **[owner authorisation]** install software or change a network/security setting and are not executed until the owner says so for that step.

## Status

| Date | What |
|---|---|
| 2026-10-20 | Read-only probe of the desktop; plan drafted. |
| 2026-10-20 | **Owner installed Tailscale on both machines and verified the tailnet.** Claude verified SSH over the tailnet by name and by IP with the existing key, and that the LAN alias still works. |
| pending | Read-only inventory of remote footage and the GPU environment (proposal below; not yet run). |
| pending | Checksummed footage/artefact transfer workflow. Remote-desktop tool choice. ACL tightening. |

## Verified connection (2026-10-20)

| Item | Value |
|---|---|
| Mac | `benjamins-macbook-pro-2` — `100.91.9.5` — macOS 26.4 — Tailscale signed in as the owner |
| Windows desktop | `bens-desktop` — `100.107.21.20` — Windows 11 **Home** 10.0.26200 — Tailscale signed in as the owner |
| `tailscale ping bens-desktop` | `pong … in 75ms` (direct, via the LAN while both are home) |
| SSH host key | identical over `BENS-DESKTOP.local`, `bens-desktop` and `100.107.21.20`: `SHA256:PbkMDzWiqVODI8G02Z1Hjn9qzvAKUw2f9eLYUVszIog` (ed25519) |
| OpenSSH server | `sshd` running, Automatic, OpenSSH_for_Windows 9.5p2, key auth via `administrators_authorized_keys`; default shell PowerShell |
| Key | `~/.ssh/bsc_desktop` (unchanged) |
| Remote Desktop | disabled; **Home edition cannot host RDP** |
| Footage | `D:\RallyLabFootage\Scratch\footage` present (read-only check) |
| GPU training | `C:\BallTraining` + `.venv` (per `desktop.sh`); contents not yet inventoried |

SSH routes on the Mac (`~/.ssh/config`; the original entry was not modified, a second block was appended; `known_hosts` gained the same host key under the two tailnet names; backups `~/.ssh/config.bak-20261020`, `~/.ssh/known_hosts.bak-20261020`):

| Alias | HostName | Use |
|---|---|---|
| `bsc-desktop` | `BENS-DESKTOP.local` | LAN only. Kept because `scripts/desktop_training/desktop.sh` hard-codes `HOST=bsc-desktop`. **Not** the Tailscale device name. |
| `bens-desktop` | `100.107.21.20` | Tailscale, works from anywhere. Same user, same key. `ssh bens-desktop` or `ssh -i ~/.ssh/bsc_desktop bwier@100.107.21.20`. |

All three (`ssh bsc-desktop`, `ssh bens-desktop`, `ssh bwier@100.107.21.20`) return `Bens-Desktop` in batch mode.

Proposed (code change, separate PR): `desktop.sh` reads `HOST=${DESKTOP_HOST:-bsc-desktop}` so `DESKTOP_HOST=bens-desktop desktop.sh status` works off-LAN without editing the script.

## Design

```
Mac (RallyLab, Core ML, review)  ──tailnet──▶  Windows desktop (footage, GPU)
   ssh bens-desktop  (OpenSSH over Tailscale, key-only)     sshd (already running)
   scp/rsync + manifest.json (SHA-256)                      D:\RallyLabFootage\<project>\footage
   remote desktop client ──────────────────▶                remote-desktop host (choice pending)
```

- **Automation:** standard OpenSSH over the tailnet. Tailscale SSH is not used: its server component runs only on Linux and macOS ([Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)).
- **Interactive access:** RDP is unavailable on Home. Options for the owner: (a) Chrome Remote Desktop, (b) Parsec, (c) RustDesk in direct-IP mode over the tailnet (keeps everything inside the private network), (d) upgrade to Windows 11 Pro and use RDP over Tailscale. Recommendation: (c); (a) if simplicity matters more.
- **Exposure:** no public port forwarding. Windows firewall keeps `sshd` (22) on the Private profile; tailnet traffic arrives on the Tailscale interface. A Tailscale ACL can restrict 22 and the remote-desktop port to the owner's devices ([ACLs](https://tailscale.com/kb/1018/acls), deny-by-default, per-port `dst`).
- **One annotation store:** the Mac RallyLab project is the only editable copy of sessions, rally marks and ball paths. The desktop holds footage, training packages, checkpoints and run outputs. Nothing on the desktop edits `sessions/*.json` or `*.rallylabels.json`.

## Steps

| # | Step | Where | Status |
|---|---|---|---|
| 1 | Install Tailscale (official installer), sign in | Windows | **done by owner 2026-10-20** |
| 2 | "Run unattended" so the node stays up with no user logged in | Windows | **[owner authorisation]** — not verified; check in the tray menu |
| 3 | Mac Tailscale client signed in to the same tailnet | Mac | **done** |
| 4 | MagicDNS; desktop reachable as `bens-desktop` | admin console | **done** (`tailscale ping bens-desktop` resolves) |
| 5 | Key expiry policy for both nodes | admin console | **[owner authorisation]** — pending choice |
| 6 | ACL: deny-by-default; owner's devices → desktop on 22 and the remote-desktop port; tag `tag:gpu` | admin console | **[owner authorisation]** — draft below; default ACL (all members ↔ all) is in force now |
| 7 | Firewall: confirm `sshd` rule scope; no change expected | Windows | verified working; **no change made** |
| 8 | Second SSH alias for the tailnet route | Mac | **done** (`Host bens-desktop`) |
| 9 | Verify SSH over the tailnet and `desktop.sh status` | Mac | SSH **done**; `desktop.sh status` over the tailnet needs the `DESKTOP_HOST` change or the LAN |
| 10 | Remote-desktop host install and tailnet-only binding | Windows | **[owner authorisation]** — tool choice pending |
| 11 | Record final configuration here; update `desktop.sh` | repo | this document (connection); script in a later PR |

Draft ACL (owner applies; replace the port with the chosen remote-desktop tool's):

```json
{
  "tagOwners": { "tag:gpu": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:owner"], "dst": ["tag:gpu:22", "tag:gpu:21118"] }
  ]
}
```

## Proposed read-only test: remote footage inventory and GPU environment

Not yet run. Every command below only reads. Nothing moves, deletes or modifies footage; no package is sent; no training starts. Output goes to the Mac scratch folder and, once reviewed, the summary is committed as `docs/ml-roadmap/manifests/Scratch-footage-<date>.json` (hashes, sizes, names) in a later PR.

**A. Footage inventory** (`ssh bens-desktop`, PowerShell):

```powershell
# 1. Tree and totals
Get-ChildItem D:\RallyLabFootage -Directory -Recurse -Depth 2 | Select-Object FullName
Get-ChildItem D:\RallyLabFootage\Scratch\footage -File -Recurse |
  Group-Object Extension | Select-Object Name, Count, @{n='GB';e={[math]::Round(($_.Group | Measure-Object Length -Sum).Sum/1GB,2)}}

# 2. Per-file size and mtime (fast; no hashing yet)
Get-ChildItem D:\RallyLabFootage\Scratch\footage -File -Recurse |
  Select-Object @{n='path';e={$_.FullName.Substring('D:\RallyLabFootage\Scratch\footage\'.Length)}}, Length, LastWriteTimeUtc |
  ConvertTo-Json -Depth 2 > C:\Users\bwier\RallyLab-inventory\scratch_footage_listing.json   # New-Item -ItemType Directory -Force C:\Users\bwier\RallyLab-inventory first; outside the footage store

# 3. SHA-256 of the small sidecars only (rally marks), to compare with the Mac
Get-ChildItem D:\RallyLabFootage\Scratch\footage -File -Recurse -Filter *.rallylabels.json |
  Get-FileHash -Algorithm SHA256 | Select-Object Hash, Path

# 4. Disk headroom
Get-PSDrive D | Select-Object Used, Free
```

Then on the Mac: `scp bens-desktop:RallyLab-inventory/scratch_footage_listing.json <scratchpad>/` (OpenSSH 9 `scp` uses SFTP, so the path is relative to the login user's home `C:\Users\bwier` and no shell variable is expanded) and compare file names against `project.json` `clipFile`s (expected: 106 videos + 140 files per the 2026-10-16 move) and the 33 sidecars still on the Mac against the desktop's hashes (expected identical; any difference means two editable copies exist and must be reconciled before any label work).

Full SHA-256 of the videos (25 GB, several minutes on the desktop) is step two of the same proposal, run only after A shows the expected file set; it produces the versioned footage manifest D-003 asks for.

**B. GPU training environment** (read-only):

```powershell
nvidia-smi
Get-ChildItem C:\BallTraining -Depth 1 | Select-Object FullName, Length, LastWriteTimeUtc
& C:\BallTraining\.venv\Scripts\python.exe -c "import sys,torch; print(sys.version); print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'no cuda')"
& C:\BallTraining\.venv\Scripts\python.exe -m pip list 2>$null | Select-String -Pattern 'torch|ultralytics|opencv|numpy|coremltools|onnx'
Get-ChildItem C:\BallTraining\runs, C:\BallTraining\bring_back -Directory -ErrorAction SilentlyContinue | Select-Object Name, LastWriteTimeUtc
Get-Process python -ErrorAction SilentlyContinue | Select-Object Id, StartTime, CPU   # is anything training now?
Get-Content C:\BallTraining\queue.txt -ErrorAction SilentlyContinue                   # queue_runner backlog, if present
```

And from the Mac on the LAN: `scripts/desktop_training/desktop.sh status` (read-only by design: it prints what is running, the queue, log tail and GPU use).

**C. What the test reports:** file counts and sizes by extension; whether the desktop file set matches `project.json`; whether sidecar hashes match the Mac; free space on D:; GPU model, driver, CUDA and torch versions; whether a run is in progress; last run folders. Any mismatch is reported, not fixed.

## Footage and artefact transfer (unchanged plan)

Versioned, checksummed, one direction at a time.

- **Footage manifest.** `D:\RallyLabFootage\<project>\footage\manifest.json` (relative path, size, SHA-256, `addedAt`, `sourceId`), generated on the desktop, committed under `docs/ml-roadmap/manifests/` so every evaluation names its footage version by hash.
- **Pull to the Mac** for evaluations that need video: `scp -r` or rsync over `bens-desktop` (rsync needs an rsync binary on Windows), then `shasum -a 256 -c` against the manifest. Copies are transient unless the owner says otherwise.
- **Push to the desktop** (training packages, val exports): `desktop.sh train/queue` as today, plus a SHA-256 check on arrival recorded in the experiment record.
- **Fetch results**: `desktop.sh fetch NAME --no-score`, hash on arrival, register in the [experiment registry](../ml-roadmap/EXPERIMENT_REGISTRY.md).
- **Never** two editable copies of annotations. The desktop receives label exports with a hash, read-only.

## Open items for the owner

1. Choice of remote-desktop tool (a–d above).
2. Authorisation for steps 2, 5, 6 and 10.
3. Go-ahead for the read-only test above (A, then full hashing; B).
4. Whether footage pulled to the Mac may persist between evaluations (25 GB for Scratch).
