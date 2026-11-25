---
id: EXP-20261110-content-lineage-prototype
status: done — prototype run once over the unreserved recordings of an isolated copy of Scratch; proposals only, nothing confirmed, nothing changed in the live project
created: 2026-11-10T21:54:02Z
updated: 2026-11-10T23:12:51Z
decision: D-036 (proposed in PR #172; owner authorisation of 2026-11-10, section "content-lineage audit")
roadmap_phase: dataset integrity (D-002, D-009, D-017, D-018)
pr: feat/content-lineage-audit
issue: n/a
---

# EXP-20261110-content-lineage-prototype — proposing copies by what the pictures do, not by bytes

An audit tool and one run of it. No model was trained. No recording in a reserved split was decoded. Nothing was written to the live Scratch project: the run read an isolated copy of its metadata and the footage on the share, and wrote under a scratch folder.

## Question

The project's leak checks compare bytes (a file fingerprint) and identities a person confirmed. Three lineage-holdout recordings were trained on under other cards because neither of those joined them (the audit record of the same date, PR #172). Can a check on the pictures themselves find such a pair with no metadata, and are there more pairs in Scratch that the cut history does not already explain?

## Method

`scripts/content_lineage/audit.py` (standard library; `ffmpeg` and `ffprobe` to read video).

- Every quarter second of a recording becomes an 8×8 grid of grey levels. The motion over half a second (a grid against the one two samples back) is kept as two 64-bit masks: cells that got brighter and cells that got darker by more than 3 grey levels. A sample with fewer than 4 moved cells says nothing.
- Two recordings are aligned by voting on the time offset at which their motion agrees, then scored at that offset. The anchors that vote come from the recording with fewer informative samples and are searched for in the other, at most 10 samples apart, so a short excerpt of a long recording is found whichever of the two is named first. The score is the share of informative aligned samples whose motion agrees. A pair is proposed when at least 40 informative samples (10 s) align and the score is 0.3 or more.
- A second signature of the centre 80 % of the frame recognises a centre crop (it must beat the full-frame score by 0.1).
- An appearance hash is kept only to say "the framing looks alike, the motion matches nowhere" (`similar_scene`), which is not a copy.
- Separately, from `project.json` alone: a card's cut history is followed back to the original file and the stretch of it, through an older project when the card was cut from that project's clip (`--origin-project`). Two cards on one original with overlapping stretches are reported (`same_source_overlap`) with nothing decoded, so this part covers reserved recordings too.
- Before any file is opened the tool computes the withheld closure and refuses to decode all of it: every recording the split manifest puts in `final_test`, `final_test_candidate`, `lineage_holdout` or `legacy_holdout`, every name `validation.json` lists, and everything that shares an identity with one of those to a fixed point (the manifest's alias group, a stored or content fingerprint, a confirmed sourceId, sessionId or venueId, on a manifest row or a card, cards read as the app reads them, the older single-`source` form included; an older card that stored no fingerprint is known by its manifest row, which carries the identity the app derived, and with no manifest row its identity is unknown here and the run stops). It also refuses any name passed with `--exclude` and any project video the manifest does not list. An unreadable manifest or `validation.json` stops the run.

Every output row has `status: proposed`. A proposal is not an identity: a person confirms it with `RallyLab --set-provenance <video> --source-id <id>`, and only that joins two recordings in the withheld closure.

### Threshold

The 0.3 threshold was set from scores measured while building the tool, on synthetic clips and on unreserved train footage:

| Pair | Score at the best offset |
|---|---|
| Unrelated stretches in front of one fixed camera | about 0.01 |
| A low-bitrate 24 fps excerpt starting between two samples (the worst true copy tried) | about 0.55 |
| Re-encoded copy, whole length | 1.0 |

The gap is wide on what was tried. It was not measured on a labelled set of known non-copies of any size, so no false-positive rate is claimed.

## Inputs

| Input | Value |
|---|---|
| Code | branch `feat/content-lineage-audit`, cut from `712f048`. Run twice over the same signatures: first with the aligner as first written, then with the aligner as corrected in review (anchors from the shorter recording). The two runs gave the same proposals, row for row; the numbers below are the second run's |
| Project metadata | isolated copy of Scratch with the D-036 correction applied (24 withheld), made from `project.json` sha256 `1364ee92aa269f71…` |
| Older project for cut history | Test1 `project.json` (read only) |
| Footage | the share copies of the unreserved recordings |
| Recordings listed | 167: 143 unreserved, 24 reserved |

## Result

| | Count |
|---|---|
| Unreserved recordings compared by pictures | 142 |
| Unreserved recordings not read (not compared, not cleared) | 1 — `grs_gnd_shade_land_self_02` (below) |
| Reserved recordings refused (not decoded, not compared by pictures) | 24 |
| Pairs proposed as copies by pictures | 7 |
| `similar_scene` pairs (not copies) | 573 |
| Pairs from cut history alone | 10 |

The seven pairs proposed by pictures, all train with train:

| A | B | Relation | Shared | Score | Cut history says |
|---|---|---|---|---|---|
| `bch_ele_sun_land_self_01` | `bch_extra_self_04` | re-encoded duplicate | 300 s | 1.0 (488/488) | IMG_3606, same stretch |
| `bch_extra_self_06` | `bch_tri_sun_land_self_01_v2` | byte identical | whole file | — | IMG_3014, same stretch |
| `bch_extra_self_16` | `bch_gnd_ovc_land_self_01` | re-encoded duplicate | 300 s | 1.0 (532/532) | IMG_0080, same stretch |
| `bch_extra_self_27` | `bch_tri_sun_land_self_01` | re-encoded duplicate | 300 s | 1.0 (499/499) | IMG_4802, same stretch |
| `ind_extra_self_01` | `ind_gnd_dim_land_self_02` | re-encoded duplicate | 300 s | 1.0 (928/928) | IMG_0393, same stretch |
| `ind_extra_self_08` | `ind_sid_dim_land_self_01` | re-encoded duplicate | 300 s | 1.0 (1091/1091) | IMG_0492, same stretch (sourceId already confirmed) |
| `ind_extra_self_05` | `ind_tri_bright_land_self_01` | overlapping ranges | 219 s at −81.25 s | 0.741 (478/645) | IMG_3427, 219.0 s shared |

The other three cut-history pairs are the holdout pairs of D-036 (IMG_0823, IMG_0822, IMG_0612); all six of their recordings are reserved after the correction, so their pictures were not compared.

The withheld closure computed by the corrected tool on this copy is the same 24 recordings the run refused (19 lineage holdout, 5 legacy holdout): no train or dev recording here is an alias of a withheld one.

The recording that was not read: the share copy of `grs_gnd_shade_land_self_02.mp4` (a train card from a YouTube link, 196 s, no reviewed frames, no recorded use, not in `rc-v1-20261108`) does not decode. ffmpeg fails on 11,686 of its 11,763 frames ("Invalid NAL unit size"), and AVFoundation reads 0 frames ("Cannot Decode", −11821). Whether the file was damaged when it was copied to the share or was like this before is not known; no other copy was compared.

What this shows:

1. With no metadata, the pictures found every train-with-train pair the cut history names, including five whose bytes differ, and placed the one partial overlap at the length the cut history gives (219 s).
2. The pictures proposed no pair that the cut history does not also name. Among the 142 recordings read, there is no further copy of the kinds the tool can recognise.
3. The six train-with-train pairs without a confirmed shared `sourceId` are duplicates inside the training pool. They leak nothing across a split today; a per-recording fold assignment that put the two members in different folds would. The correction script prepared for D-036 covers them if the owner includes them.

## Limits

- **Reserved recordings are not cleared by pictures.** Whether an unreserved recording copies a reserved one that the cut history does not connect was not tested, because that needs decoding protected footage. It needs the owner's separate approval; the tool has no switch for it. Until then the only evidence about reserved recordings is the cut history and the fingerprints.
- The third D-036 pair (`bch_extra_self_18`, `bch_tri_sun_land_self_01_v4`) still rests on card and byte evidence only.
- One unreserved recording was not read (its file does not decode) and is not cleared.
- Not recognised: a mirrored, sped-up or slowed copy; a crop that is not about the centre; an overlay over most of the frame; a stretch with no motion. Offsets resolve to a quarter second.
- A cut history is only as good as the cards: a card whose origin is a path that no project lists cannot be followed. The clip a card was registered from is found by its full path, and by file name only when exactly one card has a clip of that name; when more than one does, the card is listed as ambiguous and paired with nothing. On this run no card was ambiguous.
- The threshold has no measured false-positive rate (above).
- Footage a tester or another camera filmed of the same rally is a different recording and is not what this tool looks for; session and venue identities cover that.

## Evidence

Outside the repository, on the Mac that ran it: the proposals file (`content-lineage-proposals.json`, schema `content_lineage_proposals_v1`, signature `motion8x8_v2`) of the second run, the first run's (`proposals-first-aligner.json`), the run log and the per-recording signature cache, in `~/Movies/RallyLab/Reports/d017-correction-20261110/content-lineage/` with SHA-256 sums. Tests: `scripts/tests/test_content_lineage_audit.py` (30).

## Next

- Owner: confirm or reject the proposals; decide whether reserved recordings may be decoded once for this comparison; decide what to do with the recording that does not decode (fetch it again, or drop the card).
- If the tool is kept: run it when footage is added, before a package or dataset export, and write its `refused` and `notRead` lists into the export's record.
