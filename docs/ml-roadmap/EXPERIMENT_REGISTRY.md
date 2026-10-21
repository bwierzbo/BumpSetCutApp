---
name: experiment-registry
status: authoritative
created: 2026-10-20T22:12:44Z
updated: 2026-10-21T20:19:11Z
---

# Experiment registry

The single place that links **issues ↔ experiments ↔ datasets/splits ↔ model versions ↔ test results ↔ PRs**. Every training run, evaluation, tuning round or ablation gets a row here and a record file under `experiments/` ([template](../templates/EXPERIMENT.md)). A result that is not in this registry does not exist for decision-making.

## Identifiers

| Thing | ID form | Where it is minted |
|---|---|---|
| Decision | `D-NNN` | [DECISION_LOG.md](../decisions/DECISION_LOG.md) |
| Experiment | `EXP-YYYYMMDD-slug` | this registry |
| Dataset version | SHA-256 (first 16) of `project.json`, plus the canonical directory digest (below) of `sessions/` | computed by the evaluation command; recorded in the experiment record |
| Split version | `split_id` string + SHA-256 of the split file | `pipeline_tuning/validation.json` today; the versioned manifest once D-009 lands |
| Label set | `ball_track_truth_vN`, `rally_event_truth_vN` | D-004 / D-009 work |
| Model version | package name + canonical directory digest (first 16) of the `.mlpackage` | the `pkgdigest` command below; also the embedded `package` metadata |
| Pipeline config | SHA-256 of the serialised `ProcessorConfig` | evaluation command |
| Test results | path under `<project>/scores/<export>/` or `pipeline_tuning/report-*.md`, plus unit-test counts | experiment record |
| GitHub | `#n` issues and PRs | GitHub |

### Canonical directory digest

An `.mlpackage` (and `sessions/`) is a directory, so a single hash needs a defined file order and path encoding. The canonical digest hashes the sorted list of `"<sha256>  ./<relative path>"` lines, one per regular file, with byte-wise (`LC_ALL=C`) ordering. Two packages get the same digest only if every relative path and every file's content match; a renamed or added file changes it.

```bash
pkgdigest() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16); }
pkgdigest BumpSetCut/Resources/ML/ball_heat.mlpackage     # → 09620ab77519bd9d (2026-10-20)
```

For packages tracked in git, `git rev-parse <commit>:<path>` gives the tree object ID, which identifies the same content independently; record it alongside when available (`ball_heat` at f63bfe0: tree `4496563030b981ae`). Single files use plain `shasum -a 256`.

Hashes for the Phase 0 reference state are in [BASELINE.md](BASELINE.md), computed with this digest.

## Registry

Status: `planned`, `running`, `done`, `abandoned`. Historical rows (before this registry existed) carry what can still be recovered; blanks mean the value was not recorded at the time and must not be invented.

| ID | Date | Status | Hypothesis / purpose | Dataset / split | Models | Results | Tests | Decision | PR / issue |
|---|---|---|---|---|---|---|---|---|---|
| EXP-20260705-rally-classifier-lr | 2026-07-05 | done (historical) | Logistic regression over physics features beats rule decider on boundaries | IMG_2806 only (1 video, 9 rallies, out-of-fold) | `scripts/rally_classifier_weights.json` | startMAE 1.22→1.02 s, endMAE 0.71→0.44 s, frame AUC 0.965 | n/a | D-013 | commit c11425b |
| EXP-20261011-tune-pipeline-r1 | 2026-10-11/12 | done (historical) | Grouped sweep of ProcessorConfig knobs under the 0.25 objective | Scratch `validation.json` (tune 9 / holdout 4), sha `a47abc72dc063405` | ball_heat (Oct 9/10 model) | `Scratch/pipeline_tuning/report-20261012-0252.md`, `-0325.md` | runtime replay-parity warning only | D-011 (superseded) | commit c660c9a |
| EXP-20261012-r3-pseudo | 2026-10-12 | done (historical) | Machine labels (`--pseudo`) help | Scratch multiframe export (Oct 12) | r3_pseudo vs r3_nopseudo vs heat_20261009-2308 | val F1 0.889 / 0.895 / 0.884; beach worse with pseudo | n/a | machine labels dropped | — |
| EXP-20261013-resolution | 2026-10-13 | done (historical) | 768 / 1024 from 512 weights help | Scratch multiframe export | r3_768, r3_1024 | 0.880 (768); 1024 stopped at epoch 9 | n/a | no bigger inputs | — |
| EXP-20261016-testset-rescore | 2026-10-16/17 | done (historical) | Rank all heat models on one test set | `Scratch-val-multiframe-20261016-1100` (25 val sessions, 11,685 frames) — **also the tuning set; not independent** | 10 models, see BASELINE.md | `Scratch/scores/Scratch-val-multiframe-20261016-1100/scores.json`, sha `b92adf478ba17a5f` | n/a | shipped scratch_768_1014 (ed25d2c) | — |
| EXP-20261017-scratch-768-gray-1016 | 2026-10-17 | done (historical) | More reviewed data (26,684 windows) moves F1 | `Scratch-multiframe-20261016-2018` | scratch_768_gray_1016 | 0.888 [0.869–0.903], below Oct 14 models | n/a | recipe decided by colour twin | — |
| EXP-20261021-b1-decisions | 2026-10-21 | done | Apply D-015 to Scratch: holdout sibling, 7 provisional candidates, 73 YouTube sourceIds; re-audit | project.json `463042ef707e8360`, sessions `06ed23f06ccd23ce`, validation.json `4d4b4368ae3decad` | n/a | PROVENANCE_AUDIT_2026-10-21.md § Decisions applied; `manifests/Scratch/` | RallyLabTests 52/52; build mac | D-015; D-016 pending (pre-tracking ruling) | Task B.1 decisions PR |
| EXP-20261021-provenance-manifest | 2026-10-21 | done | First versioned split manifest + leakage audit on Scratch (Task B.1, D-002/D-009) | project.json `8404d1c0d97f10a4`, sessions `06ed23f06ccd23ce`, validation.json `a47abc72dc063405` | n/a | [PROVENANCE_AUDIT_2026-10-21.md](PROVENANCE_AUDIT_2026-10-21.md); `manifests/Scratch/` | RallyLabTests 25/25; build both targets | awaiting D-002 follow-ups (holdout sibling, final-test assignment) | Task B.1 PR |
| EXP-20261021-lineage-cut | 2026-10-21 | done | Define the model-lineage holdout (D-017) and the L2 cut-over | project.json `65243bca59895a7e`, sessions `06ed23f06ccd23ce`, validation.json `6d160a1ac00254a0` (16 `lineageHoldout`) | n/a (no training) | [MODEL_LINEAGES.md](MODEL_LINEAGES.md); audit 0 hard / 8 soft; train 133 | RallyLabTests 68/68; build mac | D-016 (amended), D-017 | PR data/d017-lineage-holdout |
| EXP-20261021-l2-scratch-prereg | 2026-10-21 | planned (preregistration proposed, **not approved**) | First L2 detector from scratch on the manifest-isolated package; recipe = shipped L1 recipe (768, colour, 60 epochs, seed 20261021) | plan `manifests/Scratch/l2/20261021-1415-plan.json` (sha `e1f3f05b7147f1af`) over project.json `65243bca59895a7e`, sessions `06ed23f06ccd23ce`, validation.json `6d160a1ac00254a0`; package not yet written | n/a (none trained) | [record](experiments/EXP-20261021-l2-scratch-prereg.md) | RallyLabTests 81/81; build mac; `--package-l2 --dry-run` on Scratch | D-017, D-018 | PR data/l2-dataset-isolation |
| EXP-20261020-phase0-baseline | 2026-10-20 | done | Lock the reference state before methodology changes | hashes in BASELINE.md | ball_heat `09620ab77519bd9d` (canonical digest; git tree `4496563030b981ae`) | BASELINE.md | build: both targets succeeded at f63bfe0 · unit suite: **not run** (no code changed; last known 377/377 on 2026-10-04) | D-001…D-010 | PR #65 |

## How a row is added

1. Create `experiments/EXP-….md` from the template with the hypothesis and frozen inputs **before** running.
2. Run. Put raw outputs where the record says (project `scores/`, `pipeline_tuning/`, desktop run folder) and hash them.
3. Fill results and the keep / revert / need-data decision. Add the row. Link the PR that carries the record.
4. If the result changes a product or architecture choice, add a decision entry and link it from the row.
