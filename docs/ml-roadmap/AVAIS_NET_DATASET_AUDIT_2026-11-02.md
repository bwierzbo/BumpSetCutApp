---
name: avais-net-dataset-audit-2026-11-02
status: report — dataset acquired, audited and packaged; at the owner approval gate; nothing trained
created: 2026-11-02T23:12:56Z
updated: 2026-11-02T23:12:56Z
decisions: owner direction 2026-11-02 on PR #132 §F.4 ("We should not have any overlapping go ahead and use it"; acquisition, forking, versioning, de-duplication and preparation authorised; training stays under an approved record); D-002, D-017, D-018 honoured
roadmap_phase: net model replacement (licensing decision 2026-10-09; plan: NET_MODEL_PLAN.md; proposed v3: NET_DETECTOR_PROVENANCE_AND_DATA_AUDIT_2026-11-02.md §E, PR #132)
---

# Avais Beach Volleyball: provenance, audit, leakage check and a training-only net package

Done on 2026-11-02, 15:45–16:20 MST. The public Roboflow project was forked into our workspace, one version was generated and exported, and every image and label was audited. The images were checked for duplicates against the other eligible net sources, and for event overlap against our recordings' metadata. A net-only package was written, hashed, verified, rebuilt byte for byte and mirrored to the desktop staging share. **Nothing was trained.** No model, application default, split, label or holdout changed. No protected recording was opened, decoded or compared by content: only names, titles, uploaders, venues, source ids and splits from the split manifest and `project.json` were read. Only the Avais images were looked at by eye (by Claude Opus 5.5, this session). None of our recordings' frames was shown to a model, so no exposure-ledger row was due. The comparison against our frames is numeric only.

**The short version.**
- **Usable:** 593 images with 593 net boxes are eligible, all from **one fixed camera at one FIVB World Tour event** (Olsztyn Grand Slam, centre court). That is one recording group's worth of net geometry, not 593 independent nets.
- **Overlap:** no exact, near or event-level overlap with protected or development footage was found. The suspected `bch_onl_sun_land_onl_03` link is ruled out by venue and date.
- **What the box measures:** the net box is useful for the **top edge** (the tape). Its **sides sit on the net's side bands, inside the posts**, about 0.035–0.04 W narrower on each side than our post-to-post corner labels.
- **Left out:** two screenshots and one mislabelled frame are quarantined; 40 near-identical frames are excluded.

## A. Provenance

| | |
|---|---|
| Source | Roboflow Universe **`avais-beach-volleyball/beach-volleyball-tt2vj`** ("Beach Volleyball", workspace "Avais Beach Volleyball"), object detection, **CC BY 4.0** (Universe listing). Created 2023-07-16T16:35Z, last updated 2025-01-01T03:00Z (project metadata). **No version existed** (0 versions, 0 downloads on Universe). |
| Source as listed today | 636 images, 0 unannotated, splits train 447 / valid 126 / test 63; class counters **Player 3,198 · Volleyball 327 · Volleyball Net 1,007**. |
| Fork | **`bumpsetcut/beach-volleyball-tt2vj-zia7d`** (fork task completed 2026-11-02T22:45:45Z). The source project was not modified. The fork's counters read **Player 2,012 · Volleyball Net 637 · Volleyball 226** on the same 636 images, which is what the exported labels contain. The source's higher counters (the "1,007 net annotations" of the earlier audit) count annotations that are not in its dataset; no exported image carries them. |
| Version | **v1** "2026-11-02 10:45pm" (created 22:45:53Z): preprocessing **auto-orient only** (no resize), **no augmentation**, 636 images (447 / 126 / 63). Same settings as `volleyball-ykkmn-grgwy` v1. |
| Export | YOLOv8, downloaded 2026-11-02T22:46:16Z, zip **162,684,934 bytes, SHA-256 `4100d851560f404e26888fdadd8d7bfdf7ac3faa4af68d91b6d83f27dc686c72`**. The zip carries `data.yaml` three times (identical 317-byte entries, one extracted). The download link carries a key and is not recorded. |
| Untouched export | `~/Movies/RallyLab/Datasets/avais-net-v1/` (+ `avais-net-v1.zip`), tree digest `7fee8aad…5fdc` (SHA-256 of the sorted per-file SHA-256 list), the same before the first build and after the last: the build never writes to it (a test checks the same on its synthetic export). |
| Classes | `0 Player`, `1 Volleyball`, `2 Volleyball Net` (`data.yaml`). |
| Licence and attribution | CC BY 4.0 as declared by the uploader on Roboflow. Attribution: *Avais Beach Volleyball, "Beach Volleyball", Roboflow Universe, https://universe.roboflow.com/avais-beach-volleyball/beach-volleyball-tt2vj, CC BY 4.0*. **Residual risk:** the frames are of a professional event, filmed by a camera whose owner is not recorded. Whether the uploader held the rights they licensed is not verifiable — the same standing as the stock photos in `volleyball-ykkmn-grgwy`. |

### Where the images come from (from file names and what is on them)

| Group | Images | Source | Evidence |
|---|---|---|---|
| `olsztyn-grand-slam-centre-court-endline` | **634** | Frames of two videos: **`2016_01_04-09_07-4797.mp4`** (619 images; 489 frame numbers 0000–0703, 130 of them twice from two different extraction passes, pixel difference 9–29 / 255, so not copies) and **`f.mp4`** (15, frames 0000–0020). | Boards read **OLSZTYN GRAND SLAM**, WARMIA MAZURY, GALERIA WARMIŃSKA, ORLEN / GŁÓWNY SPONSOR REPREZENTACJI POLSKI, FIVB WORLD TOUR. One fixed ground-level camera behind an end line, two slightly different framings (box width 0.4775 or 0.508 of the frame). Inspected: 12 seeded frames at full resolution, all 15 `f.mp4` frames, 6 same-number pairs, 10 similarity-band pairs. The year is not established from the images: `2016_01_04` is a file timestamp, not the event date. |
| `screenshot-gstaad-major` | 1 | A 3024 × 1964 macOS screenshot (2024-09-03) of a television broadcast. | GSTAAD MAJOR, BKW, coop, swatch boards; elevated broadcast camera. |
| `screenshot-bvne-santa-monica` | 1 | A 3024 × 1656 macOS screenshot (2023-07-16) of a YouTube video playing in Chrome. | Browser menu bar and player chrome in the frame; BVNE and Mikasa banners; coastal bluff and palms (Southern California). |

The earlier audit's "FIVB-style beach broadcast, elevated endline camera" was a description from sampled images. The camera is in fact **at ground level** behind the end line: lower than our elevated recordings, close to our ground-level ones.

## B. Inventory (the export, every image)

| Metric | Count |
|---|---|
| Source images (listed and exported) | **636** (train 447, valid 126, test 63) |
| Original vs augmented | 636 original, **0 augmented** (version generated with no augmentation; no two files share a hash) |
| Image sizes | 1920 × 1080: 634 · 3024 × 1656: 1 · 3024 × 1964: 1 (all JPEG; aspect 16:9 except the two screenshots) |
| Annotations by class | **Volleyball Net 637** (all boxes) · Player 2,012 (2,011 boxes, 1 polygon) · Volleyball 226 (225 boxes, 1 polygon) |
| Images with a net box | **636**; one of them with two |
| Negative images (no net) | **0** |
| Missing label files / unparseable lines / net boxes outside the frame | 0 / 0 / 0 |
| Net box (all 637), median [min–max], frame fractions | cx 0.466 [0.461–0.510] · cy 0.520 [0.407–0.565] · w 0.478 [0.022–0.608] · h 0.105 [0.056–0.157] |
| Net box, the 593 eligible | w 0.4775 [0.4744–0.5092] (≈ 917 px at 1920) · h 0.105 [0.096–0.119] (≈ 113 px) · top 0.468 [0.458–0.481] · left 0.227 [0.207–0.231] · right 0.705 [0.702–0.735] |
| Exact duplicates (file or decoded-pixel SHA-256) | **0** |
| Near duplicates (at the calibrated threshold) | **78 images in 38 clusters** (largest 4); 38 kept, **40 excluded** |
| Questionable / invalid net labels | **1** clearly wrong (frame 0157's second box, on a player); 2 screenshots of a different scene and camera; the rest consistent (robust SD of the box ≈ 0.002–0.003 of the frame) |
| Cross-source duplicates (vs `roboflow-net-v1`, vs our eligible net frames) | **0 / 0** |
| Source-event exclusions (protected or development overlap) | **0** (none found; the two screenshot groups are quarantined for source and licence reasons, not for a found overlap) |
| **Final eligible training images** | **593** (train 419 / valid 116 / test 58 in Roboflow's own split, which is meaningless for us: all train-only) |
| **Final eligible net annotations** | **593** (one box per image) |

### What "Volleyball Net" means here

One box per image around the **whole net body** (12 frames inspected at full resolution, seeded `random.seed(20261102)`, crops of both box ends):

| Part | In the box? |
|---|---|
| Top tape | **Yes — the box's top edge sits on the tape** in every inspected frame. |
| Net mesh | Yes, between the side bands. |
| Side bands / antenna line | **The box's left and right edges.** |
| Net posts (yellow pads) | **No.** Each post stands about 0.035–0.04 W outside the box (≈ 70 px at 1920). |
| Antennas, referee stand, cable to the post | No. |
| Bottom band | The box's bottom edge, roughly. |
| Partial or occluded nets | Players in front of the net do not change the box: it is drawn on the net, not on its visible part (consistent with the near-constant box). |

**Consequence for our pipeline.** Our labels are the net's four corners **post to post**: "top-left and top-right on the tape where it meets the posts" (plan §2). The gates read the box those corners span.
- **Top edge (above-net gate):** the Avais top edge is the same quantity as ours, so it is directly useful.
- **Left and right edges (off-court gate, margin 0.05 W):** these differ by definition. An Avais box is ~0.035–0.04 W narrower on each side in this camera, which is most of the gate's margin. Training the side edges on Avais boxes would teach a narrower net than our labels.
- **Corners:** no corners are annotated. **Corners derived from these boxes would not be our corners** (they would sit at the antenna line, not at the posts), and none were made.

The ykkmn photos' net polygons were not checked against this rule; their side semantics may differ again.

## C. Leakage and duplicate audit

### How each level was checked

**A. Exact duplicates.** SHA-256 of every file and of every decoded RGB pixel buffer, within the export and against every image of the compare sets:
- `~/Movies/RallyLab/Datasets/roboflow-net-v1` (the ykkmn export already used as a train-only extra, 547 images);
- `Scratch-net-20261102-0140/images` (the 129 owner-confirmed net frames of our eligible recordings, v1/v2 train and development validation).

Result: 0 within, 0 across.

**B. Near duplicates.**
- **Measure:** z-normalised 96 × 54 grayscale thumbnails (brightness- and contrast-invariant). Similarity is the best correlation between one image's full frame and the other's full frame or any of 27 crops (95, 90 and 85 % of each side, on a 3 × 3 grid of positions), taken in both directions, so a cropped, resized or shifted copy scores as high as the original.
- **Threshold:** 0.9965, fixed from a calibration on 20 seeded images of the export. The lowest similarity of each synthetic copy to its original was:

  | Synthetic copy | Lowest similarity |
  |---|---|
  | JPEG q30 | 0.99997 |
  | Half size | 0.99999 |
  | Quarter size and back | 0.99999 |
  | 5 % crop | 1.0 |
  | 10 % centred crop | 1.0 |
  | 0.5 % shift | 0.99731 |
  | 10 % brighter | 0.9969 |

  The build refuses a threshold that misses any calibrated copy.
- **Why a fixed camera complicates it:** pHash (also tried) cannot be used here: 378 of the 636 images have a pHash twin at distance 0 because the background never moves. Within the Olsztyn camera, nearest-neighbour similarity runs from 0.962 to 0.9998 (median 0.991). Pairs inspected by eye at 0.9994, 0.9975, 0.9962, 0.9950 and 0.9930 are all *different moments of play*, differing by a few pixels of player movement.
- **What the threshold therefore means:** it excludes frames that are as close to each other as a re-encoded copy. In a static video those are redundant, not leakage. Frames below it are kept.

| Compare set | Images | Matches at the threshold | Highest similarity to any Avais image | Closest pair |
|---|---|---|---|---|
| `roboflow-net-v1` (ykkmn) | 547 | 0 | 0.759 | Gstaad screenshot ↔ `195_jpg…` |
| Our eligible net frames (`Scratch-net-20261102-0140`) | 129 | 0 | **0.812** | Olsztyn frame 0217 ↔ `bch_gnd_ovc_land_self_03` (train; "Finals AA Level: Zephyr & Trent vs Mitchell & Samuel") |

The least similar pair of Olsztyn frames still scores 0.962; the 5th percentile of its nearest neighbours is 0.981. **No frame of ours comes within 0.15 of the Olsztyn camera's own spread**, so no eligible recording of ours shows that court from that camera. (The closest one is a ground-level endline view too; similar layout, different place.)

**The withheld guard.** The compare set of our frames was opened only after `--manifest` (the Scratch split manifest) passed. The guard computes the withheld closure: the 21 recordings in `lineage_holdout` / `legacy_holdout` / `final_test` / `final_test_candidate` or `reservedAs`, plus their alias groups. Any compare image named after one of them stops the build before it is opened. The net export already refuses withheld recordings, so this is a second fence: 0 hits.

**C. Event level (metadata only).** The protected closure's metadata was read from `manifests/manifest.json` and `project.json` (names, splits, alias groups, camera, uploader, venue id, source id, video title). No frame, thumbnail or file content of a protected recording was read.

| Withheld recording(s) | Surface | What the metadata says | Avais overlap? |
|---|---|---|---|
| `bch_onl_sun_land_onl_03`, `_v2` (legacy holdout) | beach | YouTube `2UUUGXanWxQ` / `julH3gK_3Yo`, uploader Dianne Gan, **venue confirmed `beach-washington-alki`** (Alki Beach, Seattle), titles **"Beach Volleyball Pick-up 7/9/26 Game 1 / Game 2"** | **No.** An amateur pick-up game in Seattle on 2026-07-09. Avais is a professional FIVB event in Poland plus two screenshots of Swiss and Californian events. The Avais project was **last updated 2025-01-01**, eighteen months **before** the game was played. Ruled out on venue, event type and date. |
| `bch_extra_self_05`, `_29`, `_30`, `_31` (lineage holdout) | beach | owner's own clips, venue `beach-colorado-memorialpark` | No: own footage at a Colorado park |
| `bch_extra_self_10`, `_18` (lineage holdout) | beach | owner's own clips, venue `beach-florida-nsb` | No: own footage in Florida |
| `grs_extra_self_02`, `_06`, `_07`, `_12`, `_14`, `_15`, `_20`, `_21` (lineage holdout) | grass | own clips at Orlando, Jacksonville, Breckenridge, Aspen | No: grass; Avais is all sand |
| `grs_onl_dusk_land_onl_03` (legacy holdout) | grass | "Prospect Park Pickup Volleyball Game 4 (7/17/25)" | No: grass, New York park |
| `ind_extra_self_06`, `_09` (lineage holdout) | indoor | own clips, `indoor-florida-ova` | No: indoor |
| `ind_onl_bright_land_onl_04`, `ind_sid_bright_land_self_02` (legacy holdout) | indoor | "The Hive Volleyball Co-ed Tournament…", "FHAC Coed Volleyball 2023…" | No: indoor |

No title, uploader, venue or source id anywhere in `project.json` or the split manifest mentions FIVB, Olsztyn, Poland, Gstaad or a World Tour event (searched). Our training recordings include amateur Southern-California YouTube footage ("CBVA Santa Monica AA FINALS", "CBVA Manhattan Beach AA FINALS", 1st Seed Volleyball). The BVNE Santa Monica screenshot could come from the same channel or beach. That would be train-to-train, not a protected overlap, but its source is unknown, so it is quarantined. Development-validation and tune recordings (`bch_ele_sun_port_self_03` "CBVA Coed A at Hermosa Pier", `bch_onl_ovc_land_onl_02*` "6v6 SAND VOLLEYBALL – I'D HIT THAT") share no event with Avais either.

### Exclusion manifest

Machine-readable: [`scripts/desktop_training/external_net_datasets/avais-net-v1.exclusions.json`](../../scripts/desktop_training/external_net_datasets/avais-net-v1.exclusions.json). It has 43 entries, each with stable id (file name and source SHA-256s), group, status, reason, evidence type, confidence, source split and the proposed correction where there is one. It is generated by the build and checked by `verify` against the package manifest it cites (digest `07c7b161…f222`).

| Id | Status | Reason | Evidence | Confidence | Event relationship |
|---|---|---|---|---|---|
| `Screenshot-2024-09-03-at-10-24-57-PM_png.rf.ab34…` | quarantined | Screen capture of a third party's broadcast (the uploader's CC BY cannot license the broadcaster's picture); one image of another event and camera | visible signage, file name | high | FIVB Gstaad Major; no relation to our footage |
| `Screenshot-2023-07-16-at-11-11-52-AM_png.rf.4655…` | quarantined | Screen capture of an unidentified online video, browser and player chrome in frame; same channel or event as our amateur SoCal training footage cannot be ruled out | visible signage, file name | medium | BVNE event, apparently Santa Monica; not protected |
| `2016_01_04-09_07-4797_mp4-0157_jpg.rf.89d6…` | quarantined | Two net boxes; line 3 (0.4878 0.5645 0.0222 0.1174) is on a player, not the net. Proposed correction for the owner: drop line 3; line 4 is the net. **Not applied**, and the source label is unchanged | manual inspection | high | Olsztyn (eligible event) |
| 40 Olsztyn frames | excluded | Near duplicate of a kept frame (named per entry; similarity ≥ 0.9965) | near_duplicate | high | Olsztyn |

### Can the eligible subset be called overlap-free?

**Yes, as far as the evidence reaches, with one stated limit.** For the 593 eligible images:
- **Duplicates:** zero exact and zero near duplicates against every eligible source we hold (our 129 confirmed net frames and the 547 ykkmn photos).
- **Event:** they come from **one identified event** (FIVB Olsztyn Grand Slam, Poland), and no recording of ours — protected, development, tune or train — is from that event.
- **The suspected Alki recording:** ruled out by confirmed venue and by date.

**The limit** is that the protected footage itself was not compared by content, by design. The conclusion rests on its metadata (confirmed venue ids, titles, uploaders, dates) plus a surface mismatch for 14 of the 21. Nothing more is needed to keep the eligible subset; the owner could ask for more only by authorising a content comparison against protected frames, which this report does not recommend.

## D. The training package

| | |
|---|---|
| Location (not in Git) | `~/Movies/RallyLab/Datasets/avais-net-v1-boxes/` (Mac) and `~/mnt/RallyLabStaging/avais-net-v1-boxes/` = `D:\RallyLabStaging\avais-net-v1-boxes` (desktop staging), both verified |
| Layout | `images/` (593 source JPEGs, **byte-identical** to the export), `labels/` (one `0 cx cy w h` line each, the source's numbers as written, class remapped `Volleyball Net`→`net`; Player and Volleyball dropped), `data.yaml` (`names: ['net']`), `provenance.json`, `manifest.json`, `exclusions.json`, `audit.json` |
| What `train_net_model.py --extra` reads | 593 images, 0 without a net, 0 with several, net class 0, provenance accepted (checked with the trainer's own `read_extra_folder`) |
| Manifest | every source image (636) with status, reason, evidence, group, size, source image and label SHA-256, package image and label SHA-256; the config's and the tool's SHA-256; class mapping; `label_kind` = **axis-aligned box, NOT four corners**; `label_semantics` (the side-band rule above); `use` = training only |
| Hashes | manifest digest **`07c7b161c0a98a7c4c5cdb67ada03a41f236c2d288665f30ac242c6df174f222`**; `manifest.json` `3c6d5ed4…7def`; `exclusions.json` `27c97de7…0221`; `audit.json` `6424333c…7118`; `provenance.json` `b1666a8a…7e9d`; `data.yaml` `ab80074f…1afa`; package tree digest `3ae621df…9b7c`; 148 MB |
| Built by | `scripts/desktop_training/prepare_external_net_dataset.py` at `f2b76a8` with `scripts/desktop_training/external_net_datasets/avais-net-v1.json` (the command is below) |

```
python -I scripts/desktop_training/prepare_external_net_dataset.py build \
  ~/Movies/RallyLab/Datasets/avais-net-v1 ~/Movies/RallyLab/Datasets/avais-net-v1-boxes \
  --config scripts/desktop_training/external_net_datasets/avais-net-v1.json \
  --compare roboflow-net-v1=$HOME/Movies/RallyLab/Datasets/roboflow-net-v1 \
  --compare scratch-net-20261102-0140=$HOME/mnt/RallyLabStaging/Scratch-net-20261102-0140/images \
  --manifest ~/Movies/RallyLab/Projects/Scratch/manifests/manifest.json
python -I scripts/desktop_training/prepare_external_net_dataset.py verify ~/Movies/RallyLab/Datasets/avais-net-v1-boxes
```

### Validation (what ran)

| Check | Result |
|---|---|
| 1. Every image decodes | yes: all 636 source images decoded during the build; `verify` decodes the 593 packaged ones and checks their size against the manifest |
| 2. Every annotation structurally valid | yes: 0 unparseable or malformed lines in the export; every packaged line is `0 cx cy w h` |
| 3. Every label refers to an existing image | yes: 593 labels for 593 images; no unlisted file in `images/` or `labels/` |
| 4. Class ids follow the mapping | yes: only class 0 `net`; `data.yaml` `['net']` |
| 5. Boxes within limits | yes: every box inside [0, 1] with positive size (0 out of frame in the export too) |
| 6. No confirmed duplicate remains | yes: exact 0; near-duplicate clusters reduced to one each; 0 cross-source |
| 7. No identified protected-source event remains | yes: none identified (§C) |
| 8. Every retained image has an auditable source | yes: one group, its evidence in the manifest |
| 9. Exported file hashes match the manifest | yes: `verify` ✅ on the Mac copy and on the desktop-staging copy |
| 10. A second build is equivalent | **byte-identical**: a second build from the same inputs into another folder, `diff -r` clean, same digest |
| Tests | `scripts/tests/test_prepare_external_net_dataset.py`: **16/16 OK** (heatconv venv); with the trainer's tests 37/37 OK; `python3 -I -m unittest discover -s scripts/tests` (CI's command) 89/89 OK |

## E. Integration with the proposed v3 recipe (recommendation; nothing implemented)

The v3 proposal (PR #132 §E) trains a pretrained backbone with a stride-8 **net-mask heatmap** and **four corner heatmaps**. It adds box-only extras as degenerate quads, with corner heatmaps placed at the box corners at weight 0.5, and runs an optional `net_v3_avais` arm. The audit changes three things for Avais:

1. **No corner supervision from Avais at all.** These box corners are at the antenna line, not at the posts, so they are not "nearly the truth" here: they are biased inwards by ~0.035–0.04 W, about the size of the off-court margin. Corner heatmaps should be supervised by our 93 frames only. The ykkmn photos need the same check before they get corner targets.
2. **Mask supervision with an ignore band.** Inside the Avais box counts as net (positive). Outside counts as background, **except** a horizontal ignore band beside each side edge (suggested 0.06 W, wider than the measured 0.035–0.04 gap) and a short band below the bottom edge. That way the mask head learns the net body without being taught that the net stops at the side bands.
3. **Top edge only, from the box.** If v3 has an explicit edge or box loss, take only the top edge (and presence) from Avais. Do not supervise its left and right edges.

**Weighting.** The 593 frames are one camera and one net. Sample extras by group, not by image: Avais as one group beside the ykkmn photos and our frames, or subsample to about 50–60 frames per epoch. Otherwise it outnumbers our 93 frames six to one with a single geometry and can pull the model towards that court.

**Arms and evaluation.** Keep `net_v3_avais` as an added arm against the same recipe without it, on v1's grouped split (36 validation frames, 15 groups). Report paired differences with the group-resampled 90 % ranges, as v1/v2 did. Avais never enters validation, model selection or hyper-parameter choice, and the 36 development frames do not change. Record the package digest (`07c7b161…`) and the attribution in the record. Expect any gain to show on ground-level endline beach views first.

**Before using it.** The owner decides on the 0157 correction (§F). A labelled second pass on a few Avais frames is unnecessary: the boxes are consistent to ~0.003 of the frame.

## F. Decisions for the owner

1. **Accept the exclusions:** the two screenshots and frame 0157 quarantined, 40 near-identical frames excluded. *Recommend yes.* The Gstaad broadcast frame could be released if you want one elevated-broadcast example despite the licence question.
2. **Frame 0157's proposed correction** (drop the player box, line 3). It can be applied as a new version in our fork, with the source untouched, and the package rebuilt (594 eligible). *Recommend: leave it quarantined*; one frame of 593 is not worth a new version.
3. **Licence standing:** the uploader's CC BY 4.0 over frames of an FIVB event whose footage owner is unknown. Training-only internal use carries a low risk, similar to the ykkmn stock photos already in use. *Recommend accept for internal training, with attribution wherever the model is described*; revisit before any public claim about training data.
4. **How Avais enters v3:** no corner targets, an ignore band at the sides, top edge and mask only, group-weighted (§E). *Recommend yes*, written into the v3 record when it is drafted. Training itself stays under that record's approval.
5. **Merge this PR** (a tool, its tests, the config and exclusion record, and this report; no app or model change). Your call after review.

## Changed files

- `scripts/desktop_training/prepare_external_net_dataset.py` (new): the audit, package and verify tool.
- `scripts/desktop_training/external_net_datasets/avais-net-v1.json` (new): source, groups, decisions, threshold, provenance.
- `scripts/desktop_training/external_net_datasets/avais-net-v1.exclusions.json` (new, generated): the 43 left-out images.
- `scripts/tests/test_prepare_external_net_dataset.py` (new): 16 tests on a synthetic export.
- `docs/ml-roadmap/AVAIS_NET_DATASET_AUDIT_2026-11-02.md` (this report), `docs/ml-roadmap/NET_MODEL_PLAN.md` (one paragraph), `docs/README.md` (index line).
