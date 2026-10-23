---
name: footage-share
status: applied 2026-10-22 (owner-authorised); kept as the record of what runs
created: 2026-10-22T00:09:39Z
updated: 2026-10-22T20:55:09Z
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

(Tick "Remember this password in my keychain". They mount at `/Volumes/RallyLabFootage` and `/Volumes/RallyLabStaging`. Terminal alternative that also prompts: `mkdir -p ~/mnt/footage && mount_smbfs //rallylab-share@100.107.21.20/RallyLabFootage ~/mnt/footage`. What runs from a terminal today, over the LAN, is `scripts/footage_share/mount_shares.sh` — see "Mounting, corrected" at the end.)

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
# an export that was cut short (its folder holds frames/ and nothing else) is completed in place, never restarted:
RallyLab --project Scratch --package-l2 --resume /Volumes/RallyLabStaging/Scratch-exports/Scratch-L2-multiframe-<stamp>
```

`--resume` completes an export that was cut short, against the journal the export writes beside its folder (`<folder>.journal.jsonl`: the run identity — exporter version, long side, JPEG quality, window settings, every clip's source path, fingerprint, size, modification date, sidecar hash and planned frame moments, plus the lineage's manifest hashes and eligible/withheld closure — then one line per frame written whole with its SHA-256, clip completions and states `in_progress` / `interrupted` / `preflight_failed` / `preflight_passed` / `finalized`). A resume refuses a folder that is not `frames/` alone, a journal whose identity differs from what the export would do now (every difference named), a journal in a finished state, a stray clip folder or a foreign file — without changing anything. A frame already there is reused only once it is read and proven: a whole JPEG of the planned size at a planned moment whose bytes hash to what the journal says was written, or — for a frame the journal does not know (the folder from before journals, or the frames after a journal's last line) — whose bytes are **identical to the frame regenerated now from the video** with the export's settings (the JPEG encoder is deterministic: eight frames of the interrupted 2026-10-21 run, regenerated read-only on 2026-10-22, matched byte for byte). Anything else is replaced and listed in `summary.json`; more than eight such files in one clip means the folder is not this export's and nothing is touched. `--resume DIR --dry-run` reads all of this without writing anything and reports what would be reused, regenerated or replaced. Fresh or resumed: a frame the export cannot decode or write stops it, naming the frame; a volume that disappears under it is noticed within seconds and is final; windows.jsonl, summary.json and the record are written only after every clip folder has been listed again and found complete, and the exposure ledger only after the preflight passed (never for a failed or interrupted folder; one row per video per package, however many runs). A resumed folder whose preflight fails keeps its frames and goes back to resumable (`MultiFramePackage`, `ExportJournal`, D-022).

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
| 2 mounts | **`mount_smbfs -N` (Keychain lookup) is refused by the server with "Authentication error"**, although the stored credential is correct (the item has no application access list, so the SMB client cannot read it without a dialog, and `-N` forbids the dialog — established on 2026-10-22, "Mounting, corrected" below). The form used that day, under the home folder rather than `/Volumes` (`~/mnt/RallyLabFootage`, `~/mnt/RallyLabStaging`), read the Keychain value into a shell variable and passed it **inside the mount URL** (`//rallylab-share:<password>@…`): the password was in that process's arguments for the moment of the mount, never in a file or a log. **Retired on 2026-10-22 by the owner's direction** (no password in process arguments, scripts, Git, logs or documentation); it is not written out here and is not to be used again. The replacement is `scripts/footage_share/mount_shares.sh`. |

| Step | What happened |
|---|---|
| 3 links | `--check`: 167 of 167 referenced videos readable, 153 of 153 L2-needed; `--link`: 167 symlinks, none blocked, ledger `footage/.rallylab-links.json`; `--check` again identical; one byte read through every Mac-side path. The 33 sidecars untouched. |
| Throughput | Bulk read ~37 MB/s (512 MB test). The export is **latency-bound, not bandwidth-bound**: it writes tens of thousands of small JPEGs over SMB, roughly 4 frames/s, so a full package takes many hours, not the hour estimated. Writing the package to the Mac's own disk would be faster but needs ~22 GB free at the 768 long side. |
| Mounts | do not survive a reboot or a long idle; remount with the commands above. A transient "Device not configured" was seen once right after deleting a folder on the staging share; the mounts recovered on their own. |
| Training from the staging share | `desktop.sh` reads a package under `~/mnt/RallyLabStaging` in place on the desktop (`D:\RallyLabStaging`, an SSD): an L2 package **folder** is verified first (`verify_package.ps1` recomputes the canonical digest on the desktop against `l2-manifest.json`; mismatch → nothing starts) and the trainer runs straight from the folder; nothing is copied or unzipped onto `C:` (39 GB free). `desktop.sh verify PACKAGE` runs the check alone; `desktop.sh plan …` shows the mapping without starting anything. |

## LAN path, as applied (2026-10-22, D-022)

The first export over the Tailscale path ran about 16 hours and failed at 10:50 UTC: the desktop's Wi‑Fi retired the temporary IPv6 address Tailscale's direct path was using (Windows rotates these daily; `netsh interface ipv6 show privacy`), both SMB sessions dropped (desktop SMB server events 1033/1034/1040 at 10:39:52Z, the open video handle scavenged at 10:42:56Z), both Mac mounts vanished and the exporter failed on its next read. The owner chose a direct LAN path restricted to the Mac, and a resumable export, keeping the partial folder.

| Change | Exactly what was done |
|---|---|
| Desktop firewall | Added `RallyLab SMB from the Mac over LAN`: inbound, allow, TCP 445, profile Private, remote address `10.0.0.113` (the Mac), local address `10.0.0.123` (the desktop), interface `Wi-Fi 2`. **Disabled** the Windows built-in `File and Printer Sharing (Restrictive) (SMB-In)` rule (`{5ABF886E-B18E-4DEC-869C-05206B626892}`), which had been enabled on the Private profile with remote address *Any* — SMB had been open to the whole home network, not only the Mac. The Tailscale rule is unchanged. Enabled inbound TCP 445 rules afterwards: exactly the two RallyLab rules. Reversible: `Enable-NetFirewallRule -Name '{5ABF886E-…}'`, `Remove-NetFirewallRule -DisplayName 'RallyLab SMB from the Mac over LAN'`. |
| Shares | Unchanged: `RallyLabFootage` Read + SMB encryption, `RallyLabStaging` Change + encryption; SMB server rejects unencrypted access. |
| Addresses | Both from the router's DHCP (desktop lease 1 day, Mac 2 days), **no reservation yet** — the owner's router (10.0.0.1) is outside the implementer's reach. If either address changes, the LAN rule fails closed (SMB refused) and the export stops on a lost volume; reserve both on the router. The Mac uses a *private Wi‑Fi address* on this network, so its reservation must use that address, not the hardware one, and the network's private-address setting must be "fixed", not "rotating". |
| Mac Keychain | A second login-Keychain item for the LAN address, same account, copied from the Tailscale item in a shell variable without printing it: `security add-internet-password -a rallylab-share -s 10.0.0.123 -r 'smb ' -l 'RallyLab footage share (bens-desktop, LAN)'`. |
| Mounts | The first LAN mount of 2026-10-22 used the Step 2 "as applied" form with the password read from the Keychain into a shell variable and passed in the mount URL — in that process's arguments for the moment of the mount, never in a file or a log; **retired the same day** by the owner's direction. This row as first written (PR #85) then claimed that `mount_smbfs -N` mounts the LAN shares **from the Keychain alone, with no password anywhere. That claim was wrong**: `-N` had succeeded only because the other share's SMB session was still open and the client reused it; with both shares unmounted it fails with "Authentication error" over the LAN exactly as it does over Tailscale. What was tried and what runs now is in "Mounting, corrected" below (`scripts/footage_share/mount_shares.sh`). Verified after mounting, both days: `link_footage.py --check` 167 of 167 readable, 153 of 153 L2-needed; a write to the footage mount is refused (read-only mount and Read share); `smbutil statshares -a`: server `10.0.0.123`, SMB 3.1.1, AES-256-GCM, signing on, encryption required. |
| Mount loss | A dropped SMB session leaves an empty local folder at the mount point; anything that keeps writing lands on the Mac's disk. The exporter anchors the package folder's device and inode and each video's, and stops on a change (`ExportIO.Anchor`). After a drop: `mount \| grep rallylab` shows nothing; remount with `scripts/footage_share/mount_shares.sh` ("Mounting, corrected" below); `link_footage.py --check` must pass again before resuming. Accidental fallback to the old path shows as `100.107.21.20` in `mount` / `smbutil statshares`. |
| IP change / reboot | Neither mount survives a reboot; the firewall rule is pinned to 10.0.0.113 → 10.0.0.123: if either lease changes, SMB is refused (fail closed) and the rule must be edited (`Set-NetFirewallRule -DisplayName 'RallyLab SMB from the Mac over LAN' -RemoteAddress <mac> -LocalAddress <desktop>`). Rollback of the whole LAN change: `Remove-NetFirewallRule -DisplayName 'RallyLab SMB from the Mac over LAN'`; the built-in rule stays disabled unless the owner wants the LAN-wide access back (`Enable-NetFirewallRule -Name '{5ABF886E-B18E-4DEC-869C-05206B626892}'`). |
| Sustained test | Three 2 GB videos read end to end at 23–26 MB/s, a 2 GB random file written to a disposable folder on the staging share (`.lan-sustain-test`, created and removed by the test) at 24 MB/s and read back byte-identical (SHA-256), 40 package frames read; both mounts still present after the test, no error. Both machines are on Wi‑Fi, so about 25 MB/s is the link, not the share. The many-small-files test ran on 2026-10-22 in the folder the owner named, `D:\RallyLabStaging\_probe`, everything it wrote confined there and removed by it afterwards: 6,000 JPEG-sized files (random bytes, ~180 KB) in three rounds of create-write-whole, read-back-and-hash, delete — 0 errors, 0 hash mismatches, 0 leftovers, both mounts present at the end. Write 7.2 files/s (per-file p50 113 ms, p95 215 ms, max 0.5 s), read 16–23 files/s, delete 22 files/s: an export's writing phase runs at about 7 frames/s over this link. |
| Stray local folders | When the mounts vanished the exporter's `createDirectory` had made empty folders under `~/mnt/RallyLabStaging/Scratch-exports/…/frames/` on the Mac's own disk (0 files); removed with `rmdir -p` before remounting. The exporter now anchors the package folder's device and inode at start and checks them, so a vanished mount is an error, not a local folder. |
| Partial package | `D:\RallyLabStaging\Scratch-exports\Scratch-L2-multiframe-20261021-1917`: kept as the owner directed; 87,589 files, 21.2 GB, newest 10:39:50Z; nothing in it was changed. |

## Mounting, corrected (2026-10-22, after the "LAN path" table was first written)

The "Mounts" row of the LAN table as first written (PR #85) said that `mount_smbfs -N` mounts the shares from the Keychain alone. **That was wrong**, and the row now says so. What was established while preparing the Stage C inspection, in order, all on 2026-10-22 (UTC):

| Attempt | Result |
|---|---|
| `mount_smbfs -N //rallylab-share@10.0.0.123/<share> <point>` — Keychain lookup, no prompt allowed | Mounts **only while an SMB session to the desktop is already open** (the other share mounted moments before): the client reuses that session's credentials. With both shares unmounted it fails at once — `mount_smbfs: server rejected the connection: Authentication error` — over the LAN exactly as over Tailscale, although the Keychain item is correct. Cause: the item was created with `security add-internet-password` and so has no application access list; the SMB client cannot read it without an authorisation dialog, and `-N` means "never ask", so nothing is sent. The 17:04 UTC claim that `-N` is Keychain-only came from the piggy-backed case; **it does not hold unattended**. |
| Finder mount — `open smb://…` or `osascript -e 'mount volume "smb://rallylab-share@10.0.0.123/<share>"'` | Raises the macOS NetAuthAgent password dialog on the screen; nothing mounts until a person answers it. With "Remember this password in my keychain" ticked the stored item gets a proper access list and later Finder mounts are silent. It needs the owner at an unlocked Mac: started from a terminal session while the owner was away, it sat on the dialog until it was killed. Mounts under `/Volumes/<share>`, not `~/mnt`. |
| Granting the SMB client access to the item — `security add-internet-password … -T /sbin/mount_smbfs -U` | Refused: `Unable to obtain authorization for this operation` (exit 44). Changing an item's access list needs the GUI authorisation dialog. Not pursued. |
| Any `security find-internet-password` read while the screen is locked | Fails with exit 152 (`Unable to obtain authorization`): the login Keychain does not answer a terminal process while the screen is locked (`CGSSessionScreenIsLocked`). Once the screen was unlocked the read raised one authorisation dialog for `security`, which the owner allowed; reads then work from a terminal while the screen is unlocked. |
| **`mount_smbfs` with its own password prompt, answered from memory** | **Works, and is the procedure now.** `scripts/footage_share/mount_shares.sh` reads the password from the Keychain into the shell's memory, hands it to a child `expect` through the environment, and `expect` types it into `mount_smbfs`'s own `Password for 10.0.0.123:` prompt (`scripts/footage_share/mount_prompt.exp`, `log_user 0`, exit code = `mount_smbfs`'s). The password is never a process argument (nothing in `ps`), never in a file, never in output or shell history; the variable is unset as soon as both mounts have been tried. The prompt pattern has to be the literal `Password for` — a case-insensitive regex did not match the prompt as `expect` saw it. Mounted this way on 2026-10-22 for the Stage C stress test and the read-only inspection; `link_footage.py --check` passed afterwards (167 of 167, 153 of 153). |

How to mount, from now on:

```bash
scripts/footage_share/mount_shares.sh            # both shares: footage read-only, staging writable; needs an unlocked screen
scripts/footage_share/mount_shares.sh --check    # what is mounted now
```

Conditions: the login-Keychain item for `rallylab-share` at `10.0.0.123` (protocol `smb `) exists; the screen is unlocked; the LAN addresses are still the ones in the firewall rule (`ipconfig getifaddr en0` on the Mac must print `10.0.0.113`, the desktop must still be `10.0.0.123` — if either changed, stop and report; do not widen the rule). After mounting, `python3 scripts/footage_share/link_footage.py --project Scratch --mount ~/mnt/RallyLabFootage/Scratch/footage --check` must pass before anything reads or writes through the share. The Finder route remains the fallback when the owner is at the machine (it needs no script, and the item it stores carries a proper access list); `~/mnt/<share>` is then made a symlink to `/Volumes/<share>` so the dataset's links keep working.

What this correction does not change: the password is still only in the Mac's login Keychain and on the desktop; the shares, the firewall rule, the accounts and the addresses are as the LAN table records them.
