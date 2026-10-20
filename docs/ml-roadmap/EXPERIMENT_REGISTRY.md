---
name: experiment-registry
status: authoritative
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
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
| EXP-20261020-phase0-baseline | 2026-10-20 | done | Lock the reference state before methodology changes | hashes in BASELINE.md | ball_heat `0f34e1208a42c1f4` | BASELINE.md | build both targets: succeeded | D-001…D-010 | Task A PR |

## How a row is added

1. Create `experiments/EXP-….md` from the template with the hypothesis and frozen inputs **before** running.
2. Run. Put raw outputs where the record says (project `scores/`, `pipeline_tuning/`, desktop run folder) and hash them.
3. Fill results and the keep / revert / need-data decision. Add the row. Link the PR that carries the record.
4. If the result changes a product or architecture choice, add a decision entry and link it from the row.
