---
id: EXP-20261112-protected-content-lineage-audit
status: planned — the tool is written and tested on synthetic data; the one run happens after review, from the reviewed commit, and its results are added here
created: 2026-11-13T00:31:22Z
updated: 2026-11-13T00:31:22Z
decision: D-036; owner authorisation of 2026-11-12, §6 "Controlled Content-Lineage Audit" (recorded verbatim with the D-036 completion record, its own PR)
roadmap_phase: dataset integrity (D-002, D-009, D-017, D-018)
pr: feat/protected-content-audit
issue: n/a
---

# EXP-20261112-protected-content-lineage-audit — one bounded, logged comparison of the withheld recordings' pictures, to find copies

An identity check. No model is trained, run or scored; no rally mark or label is read; nothing in the project is changed. This record is written before the run.

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

Not run yet. To be added: the tool's commit, the scope file and access log (SHA-256), which recordings were opened and when, each proposal with its evidence, the third pair's result, what was not read.

## Tests

`python3 -m unittest scripts.tests.test_protected_content_lineage_audit` — 12 tests on a synthetic project: the scope's checks; nothing opened and nothing logged when the scope reaches outside; each protected file on the log before it is opened; unnamed protected recordings never opened; a re-encoded copy and an excerpt of protected footage proposed, and only proposed; nothing written under the project; an unreadable file logged and not cleared; the log appended to by a second run; the ordinary audit still opens no protected recording.
