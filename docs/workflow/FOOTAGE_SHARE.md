---
name: footage-share
status: applied 2026-10-22 (owner-authorised); kept as the record of what runs
created: 2026-10-22T00:09:39Z
updated: 2026-10-22T02:05:00Z
---

# Footage over a read-only share: desktop → Mac, over Tailscale

The Scratch footage (106.7 GB, 204 files) lives on the desktop at `D:\RallyLabFootage\Scratch\footage`; the Mac has 28 GB free. The L2 package export (D-018) needs every eligible recording with labels (132 videos, 75.5 GB) and every withheld recording (21, 25.5 GB) readable at once, plus about 21 GB for the package folder and zip. The owner's decision (2026-10-21): no copy to the Mac; a **read-only SMB share** from the desktop, mounted on the Mac over the existing Tailscale link, with the package written to a **separate staging share** on the desktop. This page is the exact configuration. **Steps 1–3 were applied on 2026-10-22 under the owner's authorisation** ("Merge PR #75 and run step 1 over SSH", then "Mount them from here and run step 3"); the "As applied" section at the end records what differed from the proposal.

## What was verified before proposing (read-only checks, 2026-10-22)

| Item | Found |
|---|---|
| Tailscale | both machines on the tailnet: Mac `100.91.9.5` (`benjamins-macbook-pro-2`), desktop `100.107.21.20` (`bens-desktop`); the desktop's Tailscale interface is in the **Private** firewall profile |
| SMB server on the desktop | `LanmanServer` running; SMB2/3 on, SMB1 off, signing required, unencrypted access rejected; **no user shares exist** (only the hidden admin shares) |
| Firewall | the built-in "File and Printer Sharing (SMB-In)" rules are **disabled** on every profile; nothing listens for the Mac today |
| Desktop account | `bwier` is a **Microsoft account** (Administrator). SMB from macOS against a Microsoft account means typing that account's password into the Mac; the proposal avoids it with a dedicated local account |
| Footage folder ACL | `BUILTIN\Users` read & execute (inherited), `Authenticated Users` modify — a share with **Read** permission caps any user at read-only regardless |
| Rally-mark sidecars (`*.rallylabels.json`, 33 files next to the videos) | **all 33 differ from the desktop's copies; the Mac's are newer** (edited 2026-10-17 … 10-20; the desktop has the 2026-10-17 02:xx copies with 7 marks each). The exporter reads the sidecar next to the video, so the mount must not replace them — see "file-by-file links" below |
| Mac SMB client | `mount_smbfs` present; nothing mounted |

## Design

1. **A dedicated local Windows user** `rallylab-share`, standard (non-admin), used only for these two shares. Its password is typed once on the desktop and once into the Mac's Keychain prompt; it never appears in a script, the repo or a log. The owner's Microsoft-account password is not used anywhere.
2. **`RallyLabFootage`** — share of `D:\RallyLabFootage` with **Read** permission for that user only (effective read-only even though NTFS would allow more), SMB encryption on.
3. **`RallyLabStaging`** — share of a new, empty folder `D:\RallyLabStaging` with Change permission for that user: the only place the Mac can write. The L2 package goes there (`--out`), so the Mac's disk is not used and the zip is already on the training machine's own disk.
4. **One firewall rule**: TCP 445 inbound, **only** on the Tailscale interface, **only** from the Mac's Tailscale address `100.91.9.5`, Private profile. The built-in sharing rules stay disabled; nothing is reachable from the LAN or the internet.
5. **File-by-file links on the Mac**: every video path the project refers to (`sessions/*.json` `sourcePath`, `project.json` `clipFile`) becomes a symlink to the same relative path on the mount. The sidecars stay where they are, so the exporter uses the Mac's newer rally marks. `scripts/footage_share/link_footage.py --check` proves every needed video is present and readable before anything is exported; `--link` records every link it makes (with its target) in `footage/.rallylab-links.json`, and `--unlink` removes only those, only while they still point where recorded — a link made by anything else is left alone and reported.
6. **Fail closed in RallyLab**: `--package-l2` refuses when any eligible recording with labels has no video (`LineagePackage.exportSessions`), and the preflight check `no-missing-videos` fails a package whose summary says a clip was left out. A partial footage view can no longer produce a smaller package.

Nothing on the desktop is modified except: one local user, two share definitions, one firewall rule, one empty folder. Footage bytes, annotations and hashes are untouched; the Mac only ever reads `D:\RallyLabFootage`.

## Step 1 — Windows (PowerShell **as Administrator**, on the desktop)

Each command is one action; the owner runs them, or authorises them to be run over the existing SSH session (`ssh -t bsc-desktop`, which prompts for the new user's password on the terminal and stores nothing).

```powershell
# 1a. The dedicated user (password typed here, never stored). Standard account: not in Administrators.
$pw = Read-Host -AsSecureString "Password for rallylab-share"
New-LocalUser -Name rallylab-share -Password $pw -PasswordNeverExpires -AccountNeverExpires `
    -Description "RallyLab read-only footage share for the Mac (Tailscale only)"

# 1b. Read-only footage share. Share permission = Read for that user only; SMB3 encryption on.
New-SmbShare -Name RallyLabFootage -Path D:\RallyLabFootage -ReadAccess "BENS-DESKTOP\rallylab-share" `
    -EncryptData $true -FolderEnumerationMode AccessBased -Description "RallyLab footage, read-only"

# 1c. Staging share for the package (the only writable location). New empty folder; Modify for that user on it only.
New-Item -ItemType Directory -Path D:\RallyLabStaging | Out-Null
$acl = Get-Acl D:\RallyLabStaging
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BENS-DESKTOP\rallylab-share", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")))
Set-Acl D:\RallyLabStaging $acl
New-SmbShare -Name RallyLabStaging -Path D:\RallyLabStaging -ChangeAccess "BENS-DESKTOP\rallylab-share" `
    -EncryptData $true -Description "RallyLab package staging (Mac writes L2 packages here)"

# 1d. Firewall: SMB in, Tailscale interface only, from the Mac's Tailscale address only.
New-NetFirewallRule -DisplayName "RallyLab SMB from the Mac over Tailscale" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 445 -InterfaceAlias Tailscale -RemoteAddress 100.91.9.5 -Profile Private
```

Check (read-only):

```powershell
Get-SmbShare RallyLabFootage, RallyLabStaging | Format-List Name, Path, EncryptData
Get-SmbShareAccess RallyLabFootage, RallyLabStaging
Get-NetFirewallRule -DisplayName "RallyLab SMB from the Mac over Tailscale" | Get-NetFirewallAddressFilter
```

Expected: `RallyLabFootage` → `rallylab-share: Read`; `RallyLabStaging` → `rallylab-share: Change`; the rule's remote address `100.91.9.5`.

**Undo** (if ever wanted): `Remove-SmbShare RallyLabFootage, RallyLabStaging -Force; Remove-NetFirewallRule -DisplayName "RallyLab SMB from the Mac over Tailscale"; Remove-LocalUser rallylab-share` and delete `D:\RallyLabStaging` once its contents are kept elsewhere.

## Step 2 — macOS (the owner, in Finder or Terminal)

Mount both shares with the Keychain prompt (the password goes into the login Keychain, not into any file):

```bash
open "smb://rallylab-share@100.107.21.20/RallyLabFootage"
open "smb://rallylab-share@100.107.21.20/RallyLabStaging"
```

(Tick "Remember this password in my keychain". They mount at `/Volumes/RallyLabFootage` and `/Volumes/RallyLabStaging`. Terminal alternative that also prompts: `mkdir -p ~/mnt/footage && mount_smbfs //rallylab-share@100.107.21.20/RallyLabFootage ~/mnt/footage`.)

Check:

```bash
mount | grep RallyLab                                  # both mounted, from 100.107.21.20
ls /Volumes/RallyLabFootage/Scratch/footage/raw       # negatives  online  self
touch /Volumes/RallyLabFootage/probe 2>&1              # must fail: Permission denied (read-only)
touch /Volumes/RallyLabStaging/probe && rm /Volumes/RallyLabStaging/probe && echo staging-writable
```

## Step 3 — links and verification (Claude Code, after Steps 1–2 are confirmed)

```bash
python3 scripts/footage_share/link_footage.py --project Scratch --mount /Volumes/RallyLabFootage/Scratch/footage --check
python3 scripts/footage_share/link_footage.py --project Scratch --mount /Volumes/RallyLabFootage/Scratch/footage --link
python3 scripts/footage_share/link_footage.py --project Scratch --mount /Volumes/RallyLabFootage/Scratch/footage --check
```

`--check` must end with `L2 package needs 153 videos (132 eligible with labels + 21 withheld): 153 present, 0 missing` and exit 0. It reads one byte of every file through the mount. The 33 sidecars remain the Mac's files (a byte-for-byte comparison of the two sets is kept with the record).

## Step 4 — export (only on the owner's go-ahead after Step 3)

```bash
mkdir -p /Volumes/RallyLabStaging/Scratch-exports
RallyLab --project Scratch --package-l2 --out /Volumes/RallyLabStaging/Scratch-exports
```

Writes `Scratch-L2-multiframe-<stamp>/` and its zip on the desktop's `D:\RallyLabStaging\Scratch-exports`; the record `manifests/l2/<package>.{json,md}` on the Mac (committed to `docs/ml-roadmap/manifests/Scratch/l2/`). Expect roughly an hour: the exporter decodes ~100 GB of video over the share, and the preflight reads the written package back to hash every file. The exposure ledger on the Mac records `training_package` for every packaged recording at export time, as always.

Then the package record and hashes go into `EXP-20261021-l2-scratch-prereg` §2 and §9 for the owner's final approval. No training starts without a separate authorisation.

## Not changed by this proposal

- No Windows sharing or discovery setting beyond the two shares; no SMB1; no guest access; the Microsoft account is not used for SMB.
- No change to Tailscale ACLs (the default allows the two machines to talk; the Windows firewall rule is the gate).
- The Mac stores the share password only in its Keychain, if the owner chooses to remember it.
- `desktop.sh train` still sends the zip from a Mac path; with the zip already on `D:\RallyLabStaging`, a local copy on the desktop (`D:` → `C:\BallTraining`) is the sensible next change before training, so 10 GB does not cross the network twice. That is a later PR.

## As applied (2026-10-22)

| Step | What happened |
|---|---|
| 1a user | Created over SSH from a script file (`scp` + `powershell -File`), the password fed on stdin: the desktop's SSH shell is PowerShell and **expands `$variables` in an inline command before the script runs** — an inline attempt failed at the parser without doing anything. Description shortened to Windows' 48-character limit. The password was generated on the Mac in a shell variable and stored only in the Mac's login Keychain (`security add-internet-password -a rallylab-share -s 100.107.21.20 -r 'smb '`), never printed. Afterwards `net user rallylab-share /passwordreq:yes`. |
| 1b–1d shares, staging, firewall | Exactly as proposed; verified: `RallyLabFootage` Read, `RallyLabStaging` Change, rule on the Tailscale interface from 100.91.9.5, zero built-in sharing rules enabled. Port 445 reachable from the Mac. |
| 2 mounts | **`mount_smbfs -N` (Keychain lookup) is refused by the server with "Authentication error"**, although the stored credential is correct: mounting with the Keychain value read into a shell variable works at once. The working form, under the home folder rather than `/Volumes`: |

```bash
pw=$(security find-internet-password -a rallylab-share -s 100.107.21.20 -r 'smb ' -w | tr -d '\n')
mkdir -p ~/mnt/RallyLabFootage ~/mnt/RallyLabStaging
mount_smbfs -o rdonly "//rallylab-share:$pw@100.107.21.20/RallyLabFootage" ~/mnt/RallyLabFootage
mount_smbfs "//rallylab-share:$pw@100.107.21.20/RallyLabStaging" ~/mnt/RallyLabStaging
unset pw
```

| Step | What happened |
|---|---|
| 3 links | `--check`: 167 of 167 referenced videos readable, 153 of 153 L2-needed; `--link`: 167 symlinks, none blocked, ledger `footage/.rallylab-links.json`; `--check` again identical; one byte read through every Mac-side path. The 33 sidecars untouched. |
| Throughput | Bulk read ~37 MB/s (512 MB test). The export is **latency-bound, not bandwidth-bound**: it writes tens of thousands of small JPEGs over SMB, roughly 4 frames/s, so a full package takes many hours, not the hour estimated. Writing the package to the Mac's own disk would be faster but needs ~22 GB free at the 768 long side. |
| Mounts | do not survive a reboot or a long idle; remount with the commands above. A transient "Device not configured" was seen once right after deleting a folder on the staging share; the mounts recovered on their own. |
| Training from the staging share | `desktop.sh` reads a package under `~/mnt/RallyLabStaging` in place on the desktop (`D:\RallyLabStaging`, an SSD): an L2 package **folder** is verified first (`verify_package.ps1` recomputes the canonical digest on the desktop against `l2-manifest.json`; mismatch → nothing starts) and the trainer runs straight from the folder; nothing is copied or unzipped onto `C:` (39 GB free). `desktop.sh verify PACKAGE` runs the check alone; `desktop.sh plan …` shows the mapping without starting anything. |
