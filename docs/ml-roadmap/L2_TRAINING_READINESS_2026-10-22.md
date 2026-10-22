---
name: l2-training-readiness-2026-10-22
status: readiness check (read-only), 2026-10-22 ~05:50 UTC; no training authorised
created: 2026-10-22T05:50:00Z
updated: 2026-10-22T05:50:00Z
---

# L2 training readiness check — Windows desktop, 2026-10-22

Non-destructive check requested by the owner while the L2 export runs. Everything below was read over the existing SSH session; nothing was transferred, opened, changed or started. The incomplete export on the staging share was only listed by name. No training, no holdout access.

## 1. Host, GPU, environment

| Item | Found | Ready? |
|---|---|---|
| Host | `Bens-Desktop`, Windows 11 Home, up 187 h, SSH key-only as before | yes |
| GPU | NVIDIA GeForce RTX 3060, 12,288 MiB, driver 610.88 | yes |
| GPU **at the time of the check** | 72 % utilisation, 4,156 MiB used, 74 °C — a game (`PenguinHotel-Win64-Shipping.exe`, Steam) and Wallpaper Engine are on the GPU | **condition**: the GPU must be idle when the run starts; the queue runner only waits for other *training* processes, not for games |
| Python / torch | 3.11.9; torch 2.11.0+cu128, CUDA 12.8, `torch.cuda.is_available() == True`, device RTX 3060 | yes (matches §9 of the record) |
| Trainer dependencies | numpy 2.3.5, opencv 5.0.0, onnx 1.23.1 | yes |
| Vendored model source | `C:\BallTraining\vendor\` present (trainer uses `vball-net-pytorch-7d295c53…`; downloads the pinned zip only if absent) | yes |
| Author weights | not needed (`--from-scratch`; the trainer skips the download) | n/a |
| Disk `C:` | 38.8 GB free; the Oct 16 package still occupies 20.3 GB (`prepared/` 10.2 GB + zip 10.1 GB) | yes — L2 trains **from the folder on `D:`**, nothing is copied or unzipped onto `C:`; the run writes only `runs/heatmap/<name>/` (MBs) |
| Disk `D:` | 1,285.5 GB free (SSD); staging share holds `Scratch-exports/Scratch-L2-multiframe-20261021-1917` (in progress, not opened) | yes |
| Training / queue | no `train_heatmap_model` process; queue empty; runner not up | yes |

## 2. Scripts on the desktop vs. `main`

| File | Desktop | `main` | Note |
|---|---|---|---|
| `train_heatmap_model.py` | `72969c6f…`, 2026-10-18 | `81494cbc…` | **stale**: lacks `--score-only`, `per_clip`, `val_digest`. `desktop.sh train/queue` copies the current trainer and runner before every launch (`send_package`), so this is expected, not a blocker — but nothing must be started by hand with the old file |
| `queue_runner.ps1` | `4775bf0a…` | `7be2de96…` | stale (package-path quoting); refreshed at launch as above |
| `verify_package.ps1` | `7f92aa06…` | `7f92aa06…` | current (per-file reconciliation, JSON report) |
| `paired_compare.py` | absent | — | runs on the Mac (numpy 1.26.4 present); not needed on the desktop |

## 3. L1 baseline checkpoint

`C:\BallTraining\runs\heatmap\scratch_768_1014\`: `best.pt` 1,036,641 B, SHA-256 `46385a171fe4314581203dbbca47e0231273e08fb562313582dd82e162a56c3c` — **matches** the value in the record's §9 (read 2026-10-21). Also present: `best.onnx` `f7512159…`, `last.pt`, `metrics.json`, `log.csv`. `--score-only` will record the checkpoint's hash again in its own metrics.

## 4. The approved commands, as they will run

All launched from the Mac; the package is read in place on `D:`; the trainer runs on the desktop. `<pkg>` = `~/mnt/RallyLabStaging/Scratch-exports/Scratch-L2-multiframe-20261021-1917` (the folder, not the zip — only the folder carries `l2-manifest.json`).

| Step | Command | Gate |
|---|---|---|
| Package verification on the desktop (digest + every file by hash and size, JSON report next to the package) | `scripts/desktop_training/desktop.sh verify <pkg>` | after the export's preflight passes; before the record is completed |
| Dry mapping (nothing starts) | `scripts/desktop_training/desktop.sh plan <pkg> --size 768 --from-scratch --color --epochs 60 --seed 20261021 --name l2_scratch_768_color_s20261021` | any time after the package exists |
| L1 baseline on the L2 val windows (no training) | `scripts/desktop_training/desktop.sh train <pkg> --size 768 --color --score-only 'C:\BallTraining\runs\heatmap\scratch_768_1014\best.pt' --name l1_scratch_768_1014_on_l2val` then `desktop.sh wait` / `fetch l1_scratch_768_1014_on_l2val` | **owner's final approval** (it reads the package; it is part of the preregistered experiment) |
| The L2 run (one seed) | `scripts/desktop_training/desktop.sh train <pkg> --size 768 --from-scratch --color --epochs 60 --seed 20261021 --name l2_scratch_768_color_s20261021` then `wait` / `fetch` | **owner's final approval** |
| Paired comparison (Mac) | `python3 scripts/desktop_training/paired_compare.py incoming/l2_scratch_768_color_s20261021/metrics.json incoming/l1_scratch_768_1014_on_l2val/metrics.json --manifest ~/Movies/RallyLab/Projects/Scratch/manifests/manifest.json --out …` | after both metrics exist; exploratory reading only (D-019 amendment) |

`desktop.sh train` on a staging folder: refuses unless the folder is under the staging mount; runs `verify_package.ps1` and stops on any mismatch; copies the current trainer and runner; starts the trainer detached via WMI with the `D:` path quoted. The Mac's mounts are needed at launch (verification and path checks), not during training.

## 5. Blockers and conditions for executing the preregistered experiment

1. **The export must finish and its preflight pass** (in progress; expected many hours). Then `verify` on the desktop, then the record is completed and returned for the owner's final approval. Nothing starts before that approval.
2. **GPU must be idle at launch.** Today a game and Wallpaper Engine hold the GPU (72 %, 4.1 GB). A 768 colour run needs most of the 12 GB and the whole GPU for ~60 epochs; `desktop.sh status` shows `nvidia-smi` before launch. Ask the owner for a quiet window, or use `queue` with the owner closing the game (the runner does not wait for games).
3. **`--score-only` has never run on the GPU.** It shares the model/loader/scorer code with training, but its first real run is the L1 baseline above; a failure there would surface before the L2 run and costs minutes, not hours.
4. **Trainer refresh is implicit.** The desktop's copy is stale; only `desktop.sh` launches are valid (they copy the current files). Nothing is to be started from the desktop by hand.
5. **Mount liveness.** The footage and staging mounts do not survive a Mac reboot; remount with the commands in `FOOTAGE_SHARE.md` before `verify`/`train`.
6. **No change to the recipe** is needed or made: 768×432, colour, 9 frames, 60 epochs, batch 8 (trainer default at 768), seed 20261021, `--from-scratch`, no `--pseudo`.

Not blockers: `C:` space (training reads from `D:`), the old Oct 16 package on `C:` (left as is), `paired_compare.py` absence on the desktop (Mac-side tool).
