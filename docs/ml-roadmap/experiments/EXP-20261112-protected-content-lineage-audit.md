---
id: EXP-20261112-protected-content-lineage-audit
status: done — run once on 2026-11-12 from the reviewed commit `052484a`: all 24 opened, the three D-036 pairs confirmed by the pictures, no other copy proposed; proposals only, nothing changed in the project
created: 2026-11-13T00:31:22Z
updated: 2026-11-13T03:11:29Z
decision: D-036; owner authorisation of 2026-11-12, §6 "Controlled Content-Lineage Audit" (recorded verbatim with the D-036 completion record, its own PR)
roadmap_phase: dataset integrity (D-002, D-009, D-017, D-018)
pr: feat/protected-content-audit
issue: n/a
---

# EXP-20261112-protected-content-lineage-audit — one bounded, logged comparison of the withheld recordings' pictures, to find copies

An identity check. No model was trained, run or scored; no rally mark or label was read; nothing in the project was changed. Everything above "Results" was written before the run and is unchanged.

## Why

[EXP-20261110-content-lineage-prototype](EXP-20261110-content-lineage-prototype.md) compared the pictures of the 143 unreserved recordings of Scratch and refused the 24 withheld ones, so a copy of a withheld recording was findable only where the cut history in `project.json` names it. Three such pairs exist (D-036); the third, `bch_extra_self_18` with `bch_tri_sun_land_self_01_v4`, rests on the cut history and file fingerprints alone. Whether a withheld recording has a copy that no metadata names has not been checked.

The owner authorised that check on 2026-11-12 (§6): "The owner authorizes one bounded audit of the currently protected recordings for the sole purpose of duplicate-content identification. This is an identity-verification operation, not training, model evaluation, tuning, or annotation generation."

## Scope

The withheld closure of Scratch after the D-036 correction, 24 recordings, each named in the scope file with its reason:

- the 16 lineage-holdout recordings: `bch_extra_self_05`, `_10`, `_18`, `_29`, `_30`, `_31`; `grs_extra_self_02`, `_06`, `_07`, `_12`, `_14`, `_15`, `_20`, `_21`; `ind_extra_self_06`, `_09`;
- their three train copies, withheld as aliases by D-036: `grs_ele_sun_land_self_01`, `grs_sid_sun_port_self_01`, `bch_tri_sun_land_self_01_v4`;
- the five legacy-holdout recordings: `bch_onl_sun_land_onl_03`, `bch_onl_sun_land_onl_03_v2`, `grs_onl_dusk_land_onl_03`, `ind_onl_bright_land_onl_04`, `ind_sid_bright_land_self_02`.

Scratch has no final-test or final-test-candidate recording today. The tool refuses those and their aliases whatever the scope file says, so a later project cannot be audited past this authorisation with it.

Each of the 24 is compared with the other 23 and with every unreserved recording the ordinary audit reads. Pairs of two unreserved recordings are not recomputed (the prototype's run covers them).

## Method

`scripts/content_lineage/protected_audit.py` — its own entry point. `audit.py` is unchanged and still decodes no withheld recording.

- **Scope file.** `authorization`, `purpose` (must be "duplicate-content identification") and each recording with a reason. Before any file is opened the tool checks every name: one that is not withheld, not in the split manifest, not in the project, or in the final-test closure stops the run. A withheld recording that is not named is not opened.
- **Access log.** `access-log.jsonl` under the output folder, appended to and flushed to disk: a `run` line (project, authorisation, the names to open, every threshold of the comparison, the tool's commit and the SHA-256 of both scripts), then for each recording an `open` line **before the file is read** (name, split, why it is protected, why it is opened, path, what is done to it) and a `read` line (the file's SHA-256, samples, duration) or a `failed` line.
- **Comparison.** The same signature as the prototype (`motion8x8_v2`): an 8×8 grid of grey levels every quarter second, kept as motion masks and an average hash; alignment by voting on the offset; score at least 0.3 over at least 40 informative samples. No picture is kept.
- **Cut history.** Each pair the cut history names with an opened recording in it is listed with what the pictures found, so the third D-036 pair is answered directly.
- **Output.** `protected-content-lineage-proposals.json`: every relation `status: proposed`. A person confirms an identity with `RallyLab --set-provenance`; the tool writes nothing under the project folder and refuses an output folder inside it.

What the run does not do: run a ball, net, player, pose or rally model; read rally marks, labels or sessions (it reads `project.json`, `manifests/manifest.json`, `pipeline_tuning/validation.json`); change a reservation; decide an identity.

## Limits (stated before the run)

A mirrored, sped-up or slowed copy, a crop that is not about the centre, an overlay over most of the frame, and a stretch with no motion are not recognised. Offsets are resolved to a quarter second. "No relation proposed" is not "no copy exists", and a recording that could not be read is not cleared. A copy of a withheld recording that is not in this project at all (in another project, on the desktop, in an old package) is outside what this run sees.

## Results

Run on 2026-11-12 (evening, MST) with `scripts/content_lineage/protected_audit.py` at commit `052484a` (`protected_audit.py` SHA-256 `ec9c80745663…`, `audit.py` `48e2ef545661…`), the tool as Codex had reviewed it (PR #176), on live Scratch after the D-036 correction (project.json `bc6a5fccdb55e3f3`, manifest `fb6b540cb2bc0576`). Cut history followed through Test1's `project.json`. Signatures of the ordinary recordings came from the prototype's cache where the file's SHA-256 matched.

### What was opened

All 24 recordings of the scope, each once in the run that completed: first `open` line 2026-11-13T01:52:27Z, last `read` line 02:26:40Z, `done` 03:08:38Z. Every one was read to its end (1,032 to 1,200 samples; the file's SHA-256 is on its `read` line). None was left closed; the scope held no final-test recording (the project has none).

Two earlier attempts the same evening stopped on a stalled network share and are on the same log, which is appended to and never rewritten: the first (01:19Z) logged the `open` of `bch_extra_self_05` and read nothing; the second (01:34Z) read `bch_extra_self_05`, logged `bch_extra_self_10` as `failed` (a read time-out) and stopped during `bch_extra_self_18`. So over the three attempts `bch_extra_self_05` has three `open` lines, `bch_extra_self_10` and `bch_extra_self_18` two each, and the other 21 one each: 28 `open`, 25 `read`, 1 `failed`. The share was remounted over the local network between the second and third attempts; nothing about the tool or the scope changed.

One more access to a protected file that evening is not on that log, because it was not this tool's: while diagnosing the stalled share, a raw read of 8 MB at four offsets of `bch_extra_self_30` was attempted with `dd` to `/dev/null`. Every attempt stalled and returned nothing; nothing was decoded or kept. It is recorded here so the account is complete.

### What the pictures say

| Pair | Relation proposed | Evidence |
|---|---|---|
| `grs_extra_self_06` · `grs_ele_sun_land_self_01` (`IMG_0823`) | `re_encoded_duplicate` | offset 0.0 s, 300 s shared, 410 of 410 informative samples match (score 1.0), both 1920×1080 |
| `grs_extra_self_12` · `grs_sid_sun_port_self_01` (`IMG_0822`) | `re_encoded_duplicate` | offset 0.0 s, 300 s shared, 219 of 219 (1.0) |
| `bch_extra_self_18` · `bch_tri_sun_land_self_01_v4` (`IMG_0612`) | `re_encoded_duplicate` | offset 0.0 s, 300 s shared, 684 of 684 (1.0) |

- **The third D-036 pair is confirmed by the pictures.** It had rested on cut history and file fingerprints.
- **No other copy was proposed** for any of the 24: not among the 24, and not against the 142 ordinary recordings that were read. The three cut-history pairs with a protected member are exactly the three above; the pictures agree with each.
- 322 `similar_scene` relations (285 between a protected and an ordinary recording, 37 between two protected ones): the framing looks alike and the motion matches nowhere — the same court from the same spot at another time. Not copies; listed in the output for completeness.
- Not compared: `grs_gnd_shade_land_self_02` (ordinary, train; its file on the share does not decode). Its re-fetched copy, read on the Mac, was compared afterwards with the cached signatures of all 24 protected and the ordinary recordings — no file reopened — and matched none (`~/Movies/RallyLab/Reports/recover-grs_gnd_shade_land_self_02-20261112/signature-comparison.json`).

### What this does and does not establish

Within Scratch, no recording is a full or partial copy of a withheld recording by motion signature except the three train copies D-036 already withholds. The limits stated before the run stand: a mirrored, re-timed, off-centre-cropped, heavily overlaid or motionless copy would not be recognised, and a copy outside this project was not looked for. No identity was changed: the three proposals were already confirmed by the owner (D-036, D-037); there is nothing new to confirm.

### Evidence

`~/Movies/RallyLab/Reports/protected-content-audit-20261112/`: `scope.json` (`74cf13e76bdbb01f`), `access-log.jsonl` (`37244bf6e9bbcc5e`), `protected-content-lineage-proposals.json` (`c6cba649429a43e5`), `run3.log` (`7e28e403d083ae10`), `signatures-protected/` (24 files; motion masks and average hashes, no picture), `SHA256SUMS`.

## Tests

`python3 -m unittest scripts.tests.test_protected_content_lineage_audit` — 13 tests on a synthetic project: the scope's checks; nothing opened and nothing logged when the scope reaches outside; each protected file on the log before it is opened; unnamed protected recordings never opened; a re-encoded copy and an excerpt of protected footage proposed, and only proposed; nothing written under the project (an output folder or a signature cache inside it is refused before anything is opened; a cache miss is written where the cache was named); an unreadable file logged and not cleared; the log appended to by a second run; the ordinary audit still opens no protected recording.
