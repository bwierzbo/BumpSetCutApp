---
name: net-detector-provenance-and-data-audit-2026-11-02
status: report — investigation complete, at the owner approval gate; nothing trained, downloaded, versioned or relabeled
created: 2026-11-02T20:13:48Z
updated: 2026-11-02T20:13:48Z
decisions: owner direction 2026-11-02 §2–§7 (verbatim: ../decisions/2026-11-02-l2-tradeoff-and-net-investigation-direction.md); D-002, D-017, D-018 honoured; D-029 (§1 of the same direction) logged separately
roadmap_phase: net model replacement (licensing decision 2026-10-09; plan: NET_MODEL_PLAN.md)
---

# The net detector: where the June model came from, what net data exists, and what to run next

Metadata-only investigation on 2026-11-02 (MST). Read: the repository and its git history, the experiment records and registry, PRs #110, #128, #129 and #131, the Scratch project's label, session and manifest files, the training PC (`bsc-desktop`, read-only listings over SSH, Windows and its Ubuntu subsystem), the Roboflow workspace and the named public projects through the connected Roboflow MCP server (project, version and image metadata; no download, no version generated, no annotation touched). Nothing was trained. The protected holdout was not inspected, exposed, trained on, tuned against or evaluated; only its recording **names** were read from the split manifest, to check the sampler's Roboflow uploads against them. Numbers are **confirmed** unless marked *estimate*.

## A. Provenance of the June Ultralytics net detector — established

The bundled `BumpSetCut/Resources/ML/net.mlpackage` (committed 2026-06-19 in `b3cc952`, "net detection tab") is **byte-identical** to the Core ML export of one Ultralytics run that still exists on the training PC, in its Ubuntu subsystem: `weights/weight.bin` SHA-256 `9611a387…a280` and `model.mlmodel` `29dfa966…36d2` match `/home/bwierzbo/net/runs/train/weights/best.mlpackage/` exactly. The model's own metadata says the same: author Ultralytics, licence AGPL-3.0, "Ultralytics YOLO26n model trained on data.yaml", version 8.4.67, `date = 2026-06-19T22:54:53` (UTC), `names = {0: 'net'}`, `imgsz [640, 640]`, converted with coremltools 9.0 from torch 2.11.0+cu128.

| | What trained it | Evidence |
|---|---|---|
| Where / when | WSL Ubuntu on `BENS-DESKTOP`, `~/net/`, 2026-06-19 16:38–16:54 MDT: export downloaded 16:38, `keep_class.py` 16:41, training 16:42–16:50, Core ML export 16:54 | directory and file times; `runs/train/args.yaml`, `results.csv`; the zip `net_model.zip` (17:01, Windows Downloads) carries the same `best.mlpackage` |
| Data | Roboflow **`bumpsetcut/volleyball-ykkmn-grgwy`**, exported as a raw "dataset" export (no version existed; the data.yaml says `version: dataset`; README: "No pre-processing or augmentation was applied"; exported 2026-06-19 22:36 GMT in YOLO26 format), **547 images: train 410 / valid 98 / test 39**, classes `['ball', 'net']` | `~/net/volleyball.yolo26.zip`, `data.yaml.bak`, `README.roboflow.txt` (also in `C:\Users\bwier\Downloads\volleyball.yolo26.zip`) |
| Class mapping | `keep_class.py --keep-id 1 --name net`: every `ball` line dropped, `net` (id 1) remapped to 0, `data.yaml` rewritten `nc: 1, names: ['net']` | the script and the rewritten `data.yaml` |
| Annotation counts after the mapping | net label lines **train 440 (394 of 410 images have one; 16 are negatives), valid 102 (94 images), test 44 (38 images)** = 586 net labels, 526 images with a net, 21 without — the same 586 / 526 the Roboflow project reports today | label files counted on the PC; `images_search class=net` total 526 |
| Label geometry | **580 of the 586 net labels are polygons** (lines with more than 5 fields: 436 / 100 / 44); Ultralytics' detect task reads a polygon line as a segment and trains on its bounding box — the library's documented behaviour, *not re-verified in 8.4.67's code* | label files; the same polygons are in the 2026-11-01 v1 export (580 of 586), which is why the current trainer uses the derived `roboflow-net-v1-boxes` copy |
| Recipe | pretrained `yolo26n.pt`, `imgsz 640`, `batch -1` (auto), `epochs 100` with `patience 30` → stopped after **81 epochs**, **best epoch 51**; everything else Ultralytics defaults: `lr0 0.01`, `mosaic 1.0`, `fliplr 0.5`, `scale 0.5`, `translate 0.1`, HSV jitter, `auto_augment randaugment`, `erasing 0.4`, `cache disk`, `seed 0`, `amp` | `args.yaml` |
| Images | 640 × 640, stretched to square at upload (the project's images are 640² on Roboflow; the Net tab's commit note says "the model was trained on stretched inputs", hence `scaleFill` in `NetDetector`) | Roboflow image metadata (`width 640, height 640`); `b3cc952` |
| Historical validation (the only one that exists) | on the export's **own 98-image valid split**, best epoch: precision 0.891, recall 0.902, **mAP50 0.906**, mAP50-95 0.731 | `results.csv` row 51 |
| Checkpoint | `best.pt` SHA-256 `134fdb2f7b2313bfbeaf29387602755c8b187bc37076b6c97002ebbce5e28e44` (5.39 MB), `last.pt` identical size; both still in `~/net/runs/train/weights/` | listing on the PC |

**Where the 547 images come from.** `bumpsetcut/volleyball-ykkmn-grgwy` was created on 2024-10-15 as a **fork of the public Universe project `project-6kalp/volleyball-ykkmn`** (547 images, classes ball + net, CC BY 4.0, last updated 2024-10-15 — the same day; the `-grgwy` suffix is Roboflow's fork suffix). The images have generic names (`444.jpg`, `49_JPG.jpg`), are stock and press photographs (two of the three sampled: a branded beach-volleyball sunset photo; an APP press photo of an indoor championship in Lahore with a caption burned in), and the original photographers are not recorded. **None of them is a frame of our recordings.**

**What is still unknown.** Who annotated the 547 images and to what rule (the polygons' extent — tape only, or tape to the bottom of the mesh — has not been checked image by image); whether the project held exactly these 547 images on 2026-06-19 (the fork date and today's count agree, so most likely yes); the Ultralytics segment-to-box conversion in 8.4.67 (expected, not re-read); nothing else. **No training log of the June run other than `results.csv` exists**, and the run was never evaluated on a frame of ours.

**Old and new models did not use the same data.** The June model saw **only** the 547 Roboflow images (as boxes). The new models (`net_v1` family, v2) train on **our 93 labeled frames** and, in the `_extra` and every v2 arm, the same 547 Roboflow images as a train-only extra (boxes, via the derived copy). The owner's suspicion that the old model used Roboflow data we are not using is **not** borne out: it used a subset of what we use now, and nothing we don't.

## B. Roboflow inventory

Every project in the `bumpsetcut` workspace (7), the named public projects, and the three public ball datasets in `scripts/desktop_training/get_extra_datasets.py`. "Images with a net" is confirmed only where a class filter could be run (own workspace); elsewhere it is an estimate from annotation counts and sampled images.

### Own workspace (`bumpsetcut`)

| Project (URL slug) | Versions | Licence | Images (original / in the version) | Classes (annotations) | Images with a net | Net annotations | What the net annotation is | Camera / court | Duplicates elsewhere | Usable for the net model |
|---|---|---|---|---|---|---|---|---|---|---|
| **volleyball** (`bumpsetcut/volleyball-ykkmn-grgwy`, fork of `project-6kalp/volleyball-ykkmn`) | v1 (2026-11-01, auto-orient only, no augmentation) | CC BY 4.0 (Roboflow licence of the source; attribution required) | 547 / 547 (0 augmented) | ball 481, net 586 | **526** (confirmed) | **586** (580 polygons, 6 boxes; 47 images with more than one) | a polygon around the net — tape, mesh and in places the posts; extent per image not verified | stock and press photos: beach (sunset, branded events) and indoor arenas; broadcast, courtside and low angles; **not** the endline tripod view the product assumes; 640² stretched | generic names, no source metadata; no reason to think any is a frame of our recordings; the only net-bearing project in the workspace | **Yes — already in use** as the train-only extra (`roboflow-net-v1-boxes`, provenance recorded). Boxes only (corners unknown) |
| **BumpSetCutMore** (`bumpsetcut/bumpsetcutmore`) | v1 "2026-06-22", v2 "Training time" (21,360 images each = 3× augmentation) | own | 8,290 / 21,360 (5,482 unannotated) | ball 8,314 | 0 | 0 | — | the owner's own videos, June 2026 (`frame_NNNNNN` names; includes the "More Grass that model struggled with" batch) | frames of our recordings; **cannot be matched to recordings by name**, so whether withheld recordings are among them is unknown | No net class. Must not be used for the net model (no labels; unresolvable leakage) |
| **BumpSetCut** (`bumpsetcut/bumpsetcut-cejih`) | v1–v4 (Mar 2026; v4 3,187 images) | own | 1,325 / 3,187 (332 unannotated) | ball 1,819 | 0 | 0 | — | own videos | as above | No |
| **bumpsetcut-rallylab** (`bumpsetcut/bumpsetcut-rallylab`) | none | own | 2,457 / — (2,741 objects incl. uploads; 0 augmented) | volleyball 5,547 | 0 | 0 | — | our Scratch recordings, uploaded by the RallyLab sampler 2026-10-01; names carry the recording id (`<recording>_<frame>_<ms>.jpg`) | **checked against the 21 withheld names: 0 matches** (seven filename-pattern queries; `grs_extra_self_*` = 70 images, all `grs_extra_self_01`) | No net class |
| **Volleyball01** (`bumpsetcut/volleyball01`, copy of `volley-pjhnb/volleyball-q7cun`) | none | CC BY 4.0 (source) | 1,367 | Ball 748, Player 9,715 | 0 | 0 | — | public | identical counts to the source | No |
| **Volleyball02** (`bumpsetcut/volleyball02`) | none | unknown (source not identified) | 802 | player 4,831, volleyball 386 | 0 | 0 | — | public | — | No |
| **Volleyball03** (`bumpsetcut/volleyball03`, copy of `joergahmann/beach-volleyball-fn9rx`) | v1 (2025-08-01) 4,464 | Public Domain (source) | 4,464 | person 11,845, volleyball 5,084 | 0 | 0 | — | public beach | the Oct-2024 export in `~/Downloads/Beach-Volleyball.v1i.yolov8` is the source | No |

### Public projects named by the owner, and the extra-dataset script's three

| Project | Versions | Licence | Images | Classes (annotations) | Images with a net | Net annotations | What it is | Camera / court | Duplicates | Usable |
|---|---|---|---|---|---|---|---|---|---|---|
| **Avais Beach Volleyball** (`avais-beach-volleyball/beach-volleyball-tt2vj`) | **none** (no exportable version) | CC BY 4.0 | 636 annotated (3,187 objects in the project, most unannotated) | Player 3,198, Volleyball 327, **Volleyball Net 1,007** | *estimate ≈ 600*: 1,007 boxes over 636 images, one net box in each sampled image | **1,007** (confirmed total; more than one per image on average — unexplained, could be two halves or duplicates) | a **bounding box** on the whole net (class name; extent not checked image by image) | **FIVB beach broadcast frames, 1920 × 1080, elevated endline camera** — the closest geometry to the product's assumption | broadcast frames; our `bch_onl_*` recordings are YouTube broadcasts, so the same event could appear on both sides — **including the withheld `bch_onl_sun_land_onl_03`**; frames carry no source id, so this cannot be ruled out by metadata | Legally yes (CC BY 4.0). Technically **only after a fork into our workspace and a generated version** (both need the owner's approval); then boxes only |
| **Volleyball_net** (`tfginfo-gtd2c/volleyball_net`) | v1–v3 (each 240 images = 100 originals; v3: stretch 640², rotate ±15°, 90° turns, flips, crop 30 %, 3 outputs per image) | CC BY 4.0 | 100 originals | net 100 | *estimate 100* (one per image in the samples) | 100 | a box on the whole net | Olympic indoor broadcast (Tokyo 2020), 1280 × 720, elevated diagonal view | unknown; not our footage | Yes, but tiny and indoor-broadcast only; exportable (versions exist); a version without augmentation would be preferable — v1's preprocessing not read |
| **Volleyball Mixed Annotation** (`volleyball-training-data/volleyball-mixed-annotation`) | v1–v12 (v12: 2,528 images, stretch 1280²) | CC BY 4.0 | 2,528 (1,001 unannotated) | **NetAntenna 3,750**, person 2,517, sports ball 2,089 | **0 — antennas only** | 0 net | antenna posts, not the net | mixed broadcast | — | **No for the net**: an antenna box gives neither the tape line nor the net's extent |
| Volleyball Ball Tracking (`owens-workspace-aiu3d/volleyball-ball-tracking-0eo7r`) | v1–v5 | CC BY 4.0 | 1,765 | Volleyball-Ball-Tracking 1,348 | 0 | 0 | — | rec gym | — | No (ball only) |
| Volleyball (`volley-pjhnb/volleyball-q7cun`) | v1–v3 | CC BY 4.0 | 1,367 | Ball 748, Player 9,715 | 0 | 0 | — | — | = Volleyball01 | No |
| volleyball (`wenxuans-workspace/volleyball-7yzmq`) | v1–v3 | CC BY 4.0 | 1,691 | volleyball 2,143 | 0 | 0 | — | low angle | — | No |

**Other Universe projects with a net class, found in passing, not audited:** `osloos/volleyball-court-and-net` (732 images, instance segmentation, court + net, CC BY 4.0, v11); `volleyball-wpxi9/volleyball-uhflr` (1,018, segmentation, ball + net, CC BY 4.0); `capstone-ionaj/net-5ejfc` (476, "net ", no licence stated); `any-xfipi/net-kbdae` (1,934, "net", CC BY 4.0, sport unknown). Segmentation masks of the net would give the tape line directly (top edge of the mask); worth a look if the owner wants more box/mask data, but none was inspected here.

**Leakage, before any merge.** (1) The three own-video projects (`bumpsetcutmore`, `bumpsetcut-cejih`, `bumpsetcut-rallylab`) are ball-only and stay out of the net model; the first two cannot be de-duplicated against withheld recordings by name. (2) The 547 Roboflow photos are not video frames of ours; residual risk only if a stock photo happened to be a still from a broadcast we also recorded — negligible. (3) Avais is the real risk: broadcast frames from FIVB events, with no source id, while four of our withheld recordings are online broadcasts (`bch_onl_sun_land_onl_03`, `_v2`, `grs_onl_dusk_land_onl_03`, `ind_onl_bright_land_onl_04`). A content check against withheld footage would itself be a holdout inspection and is not proposed; the honest options are to use avais train-only and accept that a same-event frame would teach that net's position, or to leave it out (F.4).

## C. Additional training data — what would actually help

- **Our own labels: 131 labels, 129 with corners** (2 box-only), from the 138 eligible recordings less 6 side-view exclusions and 1 unlabeled; the v1/v2 runs used 129 frames from 74 recording groups (93 train / 36 val). The ceiling is **recordings, not frames**: one frame per recording group, and the project has no more eligible recordings until new footage lands. Where the corners came from: 92 of the 93 Claude-proposed labels were confirmed **without a corner being moved**; 17 of 27 old-model seeds were adjusted; 11 drawn by hand. The labels are therefore mostly the vision model's placement, accepted — a consistency question (D, hypothesis 7) more than a quantity question.
- **More frames of the same recordings** (2–3 per recording at other times, fixed camera, same corners) would add occlusion and lighting variety for the same labeling cost of zero (the corners carry over if the camera did not move — to be checked by the labeler, not assumed) but **no camera diversity**; useful as augmentation, not as new evidence. Not recommended before the recipe question (E) is settled.
- **Box-only external data:** Roboflow `volleyball-ykkmn-grgwy` 526 net images (in use), avais ≈ 600 endline-broadcast beach images (needs fork + version + the leakage decision), tfginfo 100 indoor. Together roughly **1,200 net boxes** of which only avais adds the product's camera geometry. None gives corners (D).
- **Not useful:** the antenna dataset; the ball-only projects; the own-video Roboflow projects.

## D. Old model against the new one

**Historical result (June, on Roboflow's own valid split):** mAP50 0.906 at the best epoch. A box-overlap metric on stock photos — it says nothing about the gates' units on our frames and is not comparable to anything below.

**New comparison, from existing artefacts only (no model was run).** The live-tag pass stores the old model's net box per marked recording (`VideoSession.netBox`: the median of its boxes on seven frames of the 960 px review copy). **18 of those recordings also have owner-confirmed corners** (beach 7, grass 6, indoor 5). Measuring the stored box against the corners' bounds in the trainer's units (top = the two tape ends' vertical error, mean of the two, in frame heights; sides in frame widths):

| old `net.mlpackage` | top error median / p90 (H) | left median / p90 (W) | right median / p90 (W) | within the H1 bars |
|---|---|---|---|---|
| all 18 recordings | **0.010** / 0.023 | 0.016 / 0.068 | 0.017 / 0.103 | top 15/18 · left 14/18 · right 13/18 |
| the 11 whose label did not start from the old model's own box | 0.011 / 0.023 | 0.017 / 0.287 | 0.016 / 0.253 | top 9/11 · left 8/11 · right 9/11 |

Two recordings (`bch_gnd_ovc_land_self_01_v2`, `ind_gnd_bright_land_self_01_v4`) have side errors of 0.25–0.35 W — the old model's box covers about half the net there (the median box, not a miss). Its top edge is within 0.02 H on 15 of 18.

Paired on the **7 of these recordings that are also validation frames of the v1/v2 runs** (same recordings, different frames: the label's frame for the new model, the review copy's seven frames for the old):

| | old model | `net_v2` (best so far) | old better on |
|---|---|---|---|
| top error median | **0.010** | 0.019 | 7 / 7 |
| left median | 0.006 | 0.036 | 6 / 7 |
| right median | 0.015 | 0.058 | 5 / 7 |

Caveats, all real: different frames and a different copy of the video; the old number is a median of seven boxes while the new is one frame; 4 of the 7 labels were seeded by the old model's own box (its error there is partly self-agreement); 7 recordings. The result still stands on the frames that were not seeded, and the old model's rounded error on 18 recordings sits at the bar the new model misses by half as much again. **A proper comparison — both models on the same 36 validation frames — is one `--score-only`-style run of the old Core ML model over frames already exported (dev data, exposure rows written); it is proposed in E, not done here.**

**Why the old model does better — demonstrated vs. hypothesis.**

| | Factor | Status |
|---|---|---|
| 1 | **Pretraining.** YOLO26n starts from COCO-pretrained weights; ours starts from random weights and learns edges, posts and mesh from 93 frames (+547 photos). At this data size transfer learning is usually decisive. | **Hypothesis, strongest.** Untested: no pretrained-backbone arm has been run |
| 2 | **Dense local prediction vs. global regression.** A detector head localises a box from features at the object's own location; our head regresses eight coordinates from a 4×6 (v1) or 6×10 (v2) global map through one dense layer. Coordinate regression from a pooled map is imprecise with few samples; our own ball detector went from regression to heatmaps for the same reason. | **Hypothesis, strong**; consistent with v2: 2.8× the pixels bought nothing (`net_v2_res` top 0.0425 vs control 0.0330) |
| 3 | **Training data: 547 diverse photos vs. 93 frames of 74 cameras.** The old model never saw our cameras and still does well — its data had variety, ours has coverage of one setup per recording. | Partly demonstrated (A, C); the extra 547 photos helped v1 by −0.0096 H, not told apart from zero on 15 groups |
| 4 | Training resolution | **Tested by v2: not the factor** on its own (resolution arm worse, both-arm better by −0.002 H, inside the range) |
| 5 | Augmentation | **Tested by v2: not the factor** (−0.0002 H alone) |
| 6 | **Box vs. four corners.** The gates read a box (top edge, left and right edges). The corner label was adopted for a better box in perspective views, but it makes the model learn four points from 93 frames while the only box-level supervision from the extras lands on the box the corners span. In our labels the two top corners typically share a y (the example label: TL and TR at the same height), so a box loses little. | **Hypothesis**: the corner head costs capacity on a thin target and gains nothing the gates use; untested (no box-only arm) |
| 7 | **Label consistency.** Three sources (92 unadjusted AI proposals, 27 old-model seeds, 11 by hand) and no second labeler; 0.02 H is one tape width, so a corner placed on the lower edge of the tape vs. the upper is already the whole bar. | **Hypothesis**; measurable cheaply (a second pass on 20 frames) and not measured |
| 8 | Camera-angle diversity | The v1/v2 val frames are the same cameras as train (grouped by recording, but the three surfaces share a few setups); the old model's photos are more varied. Contributes to 3; not separable here |

**The four-corner problem in training terms.** A Roboflow box supervises only `min/max` of the predicted corners (the trainer's box loss on the spanned box). It never tells the model *which* corner is where, so on 547 (+ ≈ 700 possible) extra images the corner head gets a degenerate signal and the only real corner teacher is 93 frames. Two ways out:
- **Box detector + optional corner refiner (hybrid).** Train the thing the gates need — the box — on every box we have (ours + Roboflow + avais + tfginfo ≈ 1,300 images), with a dense/heatmap head rather than a pooled regressor; keep the corners as a second small head trained on our 129 frames only (or as a later crop-and-refine stage). The gates read the box either way, so a corner head that under-performs costs nothing.
- **Heatmaps for the corners (segmentation-style), box-images as degenerate quads.** Predict four corner heatmaps at stride 8 (as the ball model does for the ball); a box-only image supervises them at the box's four corners, which for the endline view is nearly the truth (the net's top is level, the sides are the posts). This keeps one model and uses all data for every output, at the price of a small, known bias on extras.
Either beats the present "regress eight numbers from 93 frames" formulation; the hybrid is the safer bet because the box is what ships.

## E. Recommended next experiment — EXP-2026MMDD-net-model-v3 (one design; not approved, not run)

**Question.** Does a pretrained-backbone, dense-head net detector meet the gates' bars on our grouped validation frames, where the from-scratch regressor (v1, v2) did not — and how does it compare with the June Ultralytics model on the same frames?

**Model (non-Ultralytics, from torchvision).** Backbone: `torchvision` MobileNetV3-Large or ResNet-18 with ImageNet weights (torchvision code and weights are BSD-3-Clause; no Ultralytics code, data or weights anywhere in the chain). Head: stride-8 heatmaps on a 640×360 letterbox — one **net mask** (inside the box: supervised on every image) and **four corner heatmaps** (supervised on our frames at the labeled corners; on box-only images at the box's corners, weighted 0.5 to mark the bias). Decode: box = the mask's bounds (what the gates read), corners = heatmap argmax (reported; not what the gates read). Export with coremltools as the ball model is. About 3–5 M parameters; one arm trains in well under an hour on the RTX 3060.

**Arms (all on v1's `split.json`, seed 0, 40 epochs unless the loss is still falling — then report, as v2 did):**
1. `net_v3` — the model above, trained on our 93 frames + `roboflow-net-v1-boxes` (as v2 did).
2. `net_v3_scratch` — same, random initialisation (isolates hypothesis 1).
3. `net_v3_box` — same as 1 with the corner heads removed (isolates hypothesis 6; the gates' metrics are unchanged by it).
4. *(if F.4b is approved)* `net_v3_avais` — arm 1 plus the avais boxes (train only).

**Baselines, on the identical 36 validation frames.** `net_v2` (frozen checkpoint, scored as is) and the **June `net.mlpackage`**, run once over the 36 exported validation frames with the Swift `NetDetector` (scaleFill, as the app runs it) — a use of an existing model on development frames, recorded in the exposure ledger (`net_proposal`-style row per recording, ref = the record id), no training. This is the quantitative old-vs-new comparison the v1 record deferred, done on the same reviewed frames with the same metrics.

**Metrics.** v1's, unchanged: detect rate at presence 0.5; top error (tape ends, mean of the two, H) median / p90; left and right errors (W); corner error; IoU; by surface and recording group; 90 % ranges from resampling the 15 groups; paired differences against both baselines with 90 % ranges and frame counts.

**Acceptance (preregistered).** H1 as before: median top ≤ 0.02 H, median left and right ≤ 0.05 W, detect ≥ 0.95 — on all val frames and on no surface worse than 1.5× the bar. H2 (the swap bar): paired against the June model, the 90 % range of the median top-error difference excludes "worse by more than 0.005 H". A model that passes H1 and H2 is a candidate for the replacement PR's end-to-end gate diagnostic; one that passes H1 only is reported and the owner decides.

**Leakage controls.** The withheld closure refused by the export and the trainer against the split manifest, as today; validation by whole recording groups; extras train-only with `provenance.json`; the June model scored only on frames already exported (no new recording opened); avais, if used, train-only and flagged as a possible same-event source for the withheld online recordings; the protected holdout untouched; no new frames labeled for this record.

**What v2 already settled, so v3 does not re-run it:** resolution alone and augmentation alone; v3 keeps v2's 640×360 and strong augmentation as the fixed recipe.

## F. Decisions for the owner (recommendation in bold)

1. **The accepted tradeoff and the shipped configuration (D-029 item 2).** The figures accepted in §1 are L2 *with the retuned decider settings* (join 0, postroll 1.0, preroll 2.0, min clip 1.5 s). #110 ships L2 at the committed settings, which score below L1 on every count. **Recommend:** rebase #110, add the four defaults as a second commit on both apps, amend D-026 to say so, re-review; merge only on your word. Alternative: hold #110 until the classifier work starts.
2. **Merge this PR** (D-029 recorded as accepted on your §1, the verbatim note, this report). **Recommend yes**; it changes no code.
3. **Net v3 record (E) — allow a torchvision ImageNet-pretrained backbone.** Not Ultralytics; BSD-3 weights. **Recommend yes**: the single most likely fix.
4. **Avais Beach Volleyball.** (a) Fork into our workspace and generate one version (a new dataset version in our workspace; metadata-only until downloaded) — **recommend yes**, it is the only endline-broadcast net data. (b) Use it train-only despite the possible same-event overlap with the four withheld online recordings — **recommend yes, with the risk stated in the record**; if you want zero holdout risk, leave it out and v3 runs on today's extras.
5. **Score the June `net.mlpackage` on the 36 development validation frames** (ledger rows written, no training) as v3's second baseline. **Recommend yes**; it is the comparison the records keep deferring.
6. **Close the v1 and v2 records.** Both are *H1 not met, decision pending*. **Recommend** "revert — new recipe under EXP net-model-v3" for both when v3's record is approved (the other instance's branches are not touched by this PR).
7. **Extra frames per recording / a second labeler pass on 20 frames** (hypothesis 7). **Recommend the 20-frame consistency check** (cheap, settles whether the bar is even measurable at one tape width); the extra frames can wait.

Nothing above is started. The net work's current branches (`exp/net-model-v1-run` #128, `exp/net-model-v2-run` #131, the other instance's worktree) were read, not modified.
