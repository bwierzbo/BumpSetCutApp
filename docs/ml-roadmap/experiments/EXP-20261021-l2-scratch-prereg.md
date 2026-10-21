---
id: EXP-20261021-l2-scratch-prereg
lineage: L2
status: proposed
created: 2026-10-21T20:19:11Z
updated: 2026-10-21T20:44:30Z
approved_by: not yet
decision: D-017, D-018
pr: data/l2-dataset-isolation
---

# EXP-20261021-l2-scratch-prereg — first L2 detector, from scratch, on the manifest-isolated package

**Status: proposed for owner review. Not approved; no package exported; no training started.** This record follows [PREREGISTRATION_L2.md](../../templates/PREREGISTRATION_L2.md). Fields marked `not fixed` must be filled (after the package is written and verified) before the owner can approve it; nothing is trained before that approval.

## 1. Objective and hypotheses

Establish the first model of lineage L2 ([MODEL_LINEAGES.md](../MODEL_LINEAGES.md)): a ball detector with **no training, tuning or selection exposure** to the 16 lineage-holdout recordings, trained from independent initialisation on a package whose contents are chosen from the split manifest and verified by preflight.

- **H1 (recipe reproduction).** The shipped L1 recipe (VballNetV4c, from scratch, colour, 768×432, 60 epochs) trained on the L2 package reaches a dev_val+tune F1 on balls in play within the L1 shipped model's 90 % interval (0.879–0.922 on the Oct 16 test set, which is **not** the same val set: L2's val loses the five legacy-holdout clips, so the comparison is indicative only). Falsified if the L2 F1 interval lies entirely below 0.879.
- **H2 (holdout generalisation, diagnostic for L1, valid for L2).** On the lineage holdout, the L2 model's detector score per surface is reported next to the L1 shipped model's score marked *exposed, diagnostic-only*. No hypothesis about their order is preregistered: the holdout has **no reviewed ball labels today** (§8), so this evaluation cannot run until Task B.2 produces them. The L2 run is still worth doing now because it fixes the lineage and its package; the holdout look happens once, later, by §8.

## 2. Data

| Field | Value |
|---|---|
| Split manifest hashes | project.json `65243bca59895a7e` · sessions `06ed23f06ccd23ce` · validation.json `6d160a1ac00254a0` (the D-017 cut-over state) |
| Lineage plan | `manifests/l2/20261021-145541-plan.json`, SHA-256 `11d13b3843345c18…` (committed under [`manifests/Scratch/l2/`](../manifests/Scratch/l2/20261021-145541-plan.md)) |
| Package name | `Scratch-L2-multiframe-<stamp>` — **not written yet** (`RallyLab --project Scratch --package-l2`; needs the footage on the Mac) |
| Package digest · windows.jsonl SHA-256 | not fixed (from `l2-manifest.json` after export) |
| Preflight | not run (11 checks: windows-clips-eligible, windows-clips-not-withheld, frame-paths-eligible, no-machine-labels, frame-files-exist, no-stray-files, frame-dirs-have-windows, no-protected-content, **sources-not-protected** (the video file behind every packaged clip fingerprinted and compared with every identity a withheld recording's video can carry — project fingerprint, cut file, session file — over the full withheld closure, sessionless project videos included), **sources-disjoint-across-splits** (no video file on both the train and the val side), both-splits-present; plus the plan's hard-leak, reservation-agreement and identity-closure checks) |
| Train recordings / windows | 133 eligible train recordings; from the labels that exist today, **76 contribute windows: 27,067 labeled + 246 dead-time** (computed from the Oct 16 package, every one of whose 76 train clips is L2-eligible; the other 57 train recordings have no reviewed labels yet) |
| Val recordings / windows | 13 eligible (dev_val 4 + tune 9): `bch_ele_sun_port_self_03`, `bch_onl_ovc_land_onl_02`(+v2,v3,v4), `grs_hnd_shade_port_self_02`, `grs_onl_shade_land_onl_02`, `grs_onl_sun_land_onl_01`(+v2), `ind_ele_bright_land_self_01`, `ind_ele_dim_land_self_02`(+v2,v3); 12 have labels today: **4,778 labeled val windows** (the Oct 16 package's val minus the 1,549 windows of the five legacy-holdout clips) |
| Withheld | 21: `lineage_holdout` 16 (D-017; all 16 have **0 reviewed frames** and never entered a package) + `legacy_holdout` 5 (`bch_onl_sun_land_onl_03`, `_03_v2`, `grs_onl_dusk_land_onl_03`, `ind_onl_bright_land_onl_04`, `ind_sid_bright_land_self_02`, which **were** val clips of every L1 package); final test 0, candidates 0 |
| Provenance summary | audit 0 hard / 8 soft / 21 info; 144 train/dev recordings have neither confirmed venue nor session (`LINEAGE-UNKNOWN-RELATIONS`): their relation to the holdout is unknown, not cleared |
| Label sets | **Ball tracks (human-verified, complete-rally).** Annotation process, as stated by the owner on 2026-10-21: an L1 model first proposed ball tracks for a rally; the owner then personally reviewed and corrected every track and ensured the *entire* rally was tracked, including the portions the model had initially missed. The resulting labels are human-verified, complete-rally ball-tracking annotations — not unreviewed machine labels and not pseudo-labels (the Oct 16 package: 33,394 tracked windows, 0 machine frames). **Approved by the owner for L2 detector training.** Rally marks: 22 eligible recordings fully marked (used for dead-time windows only). Independently reviewed **serve-contact and dead-ball boundaries are a separate label set** that does not exist yet; Task B.2 produces it (D-004). No versioned label-set IDs exist yet (D-009 work) |
| Exposure ledger | the export adds `training_package Scratch-L2-multiframe-<stamp>` for every packaged recording; nothing for the withheld |

## 3. Model and initialisation

VballNetV4c (vendored at commit `7d295c53fa73…`, MIT), 9 consecutive frames in colour (27 input channels), 768×432, heatmap + log-radius heads; ~524 K parameters (the shipped L1 model's count). **Initialisation: random, `--from-scratch`, seeded (§4).** The author's published beach weights and every L1 checkpoint (including the shipped `ball_heat` = `scratch_768_1014`) are excluded as initialisation. Trainer: `scripts/desktop_training/train_heatmap_model.py` at the code SHA recorded in §9.

## 4. Training (proposed)

| Field | Value |
|---|---|
| Command | `scripts/desktop_training/desktop.sh train <Scratch-L2-multiframe-<stamp>.zip> --size 768 --from-scratch --color --epochs 60 --seed 20261021 --name l2_scratch_768_color_s20261021` |
| Epochs · batch · lr · optimiser | 60 · 8 (trainer default at 768) · 1e-3 (trainer's from-scratch default) · the trainer's optimiser and schedule unchanged |
| Augmentations | the trainer's defaults for `--color` (channel shuffle, saturation) only; `--aug`, `--occluded`, `--qfl`, `--mine` **off** (each is a separate preregistered experiment); `--pseudo` **off and forbidden** for L2 (a model-written label is L1 output; the preflight's `no-machine-labels` check fails the package if any is present) |
| Seed | 20261021 (a second seed, 20261022, is preregistered as the noise estimate if the owner approves two runs) |
| Stopping | fixed 60 epochs; the checkpoint with the best §5 metric is kept (`best.pt`) |
| Precision | the trainer's autocast with float32 heads, as shipped |

Why this recipe: it is the shipped L1 recipe (`scratch_768_1014`), so the first L2 number is comparable to the known state rather than a new variable. Resolution and augmentation ablations come after, each on its own record.

## 5. Development validation and checkpoint selection

Val = the package's val windows (dev_val + tune recordings above). Selection metric = the trainer's **F1 on balls in play at 4 px (512-width scale) over tracked-rally windows**, computed every epoch; the best epoch's checkpoint is `best.pt`. Two runs are told apart only when their 90 % video-resampling intervals do not overlap. No holdout number is used for any of this.

## 6. Metrics

Detector (trainer's `metrics.json`): precision, recall, F1 on balls in play at 4 px and 8 px; resting-ball recall; occluded frames neither hit nor miss; dead-time fire rate (windows with a fire, peaks per window). End-to-end rally metrics are **not** part of this run: they need the corrected raw-vs-padded scorer and B.2 boundary truth (roadmap Phase 1A/2), and the seven candidates have no trustworthy rally marks yet.

## 7. Reporting by surface and uncertainty

Per surface (beach / grass / indoor) and per clip card, with window counts; 90 % intervals from resampling whole val videos (the trainer's method). With 12–13 val recordings, a surface with fewer than 3 recordings is reported as *indicative only*.

## 8. Protected-holdout access and evaluation

The 16 lineage-holdout recordings have **no reviewed ball labels and no rally marks** (D-017 §3; `LINEAGE-HOLDOUT-SUMMARY`); the pre-tracking machine tracks are not ground truth. Therefore **no holdout evaluation is preregistered for this run.** When Task B.2 produces reviewed labels for them, a separate preregistration names the single L2 candidate to be evaluated, the command (`--score-heat` on a `--val-only`-style export restricted to the holdout, written by a lineage-aware exporter still to be built), and the per-surface / per-group report; that evaluation is logged as `detector_evaluation` on every holdout recording. The L1 shipped model's score on the same export is reported alongside, marked *exposed, diagnostic-only*. Repeated looks and any selection on these numbers are forbidden.

## 9. Reproducibility

| Field | Value |
|---|---|
| Code SHA · trainer SHA-256 · model source commit | not fixed (filled at approval: repo SHA, `shasum -a 256 scripts/desktop_training/train_heatmap_model.py`, `VBALLNET_COMMIT`) |
| Hardware | `bens-desktop` (Windows, NVIDIA GPU — model and driver recorded by `desktop.sh status` at start) |
| Versions | python, torch, CUDA, opencv, numpy, onnx, coremltools: recorded from the training machine's `.venv` at start; not fixed |
| Package transfer | zip sent by `desktop.sh`; **the digest in `l2-manifest.json` is recomputed on the desktop before training and must match.** The digest covers every file except `l2-manifest.json` itself (a record cannot hold its own hash): in the unpacked folder, `find . -type f ! -name l2-manifest.json -print0 \| LC_ALL=C sort -z \| xargs -0 shasum -a 256 \| shasum -a 256` (PowerShell equivalent on the desktop), compared with `preflight.digest`; each payload file's SHA-256 is also in `preflight.files` |
| Artefacts | `bring_back/<name>/{best.pt,best.onnx,metrics.json}` hashed; the converted `.mlpackage` canonical digest (`pkgdigest`) recorded at `--add-heat` |

## 10. Success, failure and limitations

- **Success (candidate):** H1 holds on dev_val+tune; the exposure ledger shows only `training_package Scratch-L2-…` for the 76+12 packaged recordings and nothing for the 21 withheld; `l2-manifest.json` preflight passed.
- **Failure:** H1 falsified → the recipe is re-examined on L2 data before any other L2 experiment; a failed preflight or a ledger row on a withheld recording → the run is void and the package is deleted.
- **Limitations:** (1) L2's val is smaller than L1's and not the same set, so L1–L2 numbers are indicative; (2) the holdout cannot be evaluated until labels exist; (3) 144 train/dev recordings have unknown venue/session relations to the holdout; (4) the ball labels are human-verified and complete per rally (§2), but the *selection* of which rallies were tracked started from L1 proposals, so a rally the L1 model never proposed may be under-represented — a possible model-assisted rally-selection bias, noted, not a label-quality limitation; (5) broad generalisation claims still need the planned new-footage final test.

## Approval
- [x] Owner approved the ball-tracking annotations for L2 detector training on 2026-10-21 ("These are human-verified, complete-rally tracking annotations … The annotations are approved for L2 detector training.").
- [ ] Owner approved this preregistration on <date> (quote the authorisation).
- [ ] Dataset preflight passed (package name, digest).
- [ ] Training started on <date>; holdout not yet evaluated.
