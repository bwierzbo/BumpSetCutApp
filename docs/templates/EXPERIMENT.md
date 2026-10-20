# Experiment record template

One file per experiment at `docs/ml-roadmap/experiments/EXP-YYYYMMDD-<slug>.md`, plus a row in [`EXPERIMENT_REGISTRY.md`](../ml-roadmap/EXPERIMENT_REGISTRY.md). Write the hypothesis **before** running. Never write `0` for a metric that was not computed; write `not measured`.

```markdown
---
id: EXP-YYYYMMDD-slug
status: planned | running | done | abandoned
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
decision: D-NNN
roadmap_phase: <phase or matrix ID, e.g. Phase 4 / E02>
pr: <#n or n/a>
issue: <#n or n/a>
---

# EXP-YYYYMMDD-slug — <title>

## Hypothesis
<One sentence: control → treatment, expected effect, on which metric.>

## Inputs (frozen)
| Input | Value |
|---|---|
| Code SHA | |
| Dataset manifest SHA-256 | |
| Split ID / version | |
| Label set version(s) | ball_track_truth_vN, rally_event_truth_vN |
| Control model (name, SHA-256) | |
| Treatment model(s) (name, SHA-256) | |
| Pipeline config SHA-256 | |
| Trainer / converter versions | script SHA, torch, coremltools |
| Seeds | |
| Compute | machine, GPU, wall time |

## Procedure
<Commands, exactly as run. Where outputs live (`<project>/scores/...`, desktop path).>

## Results
<Tables by surface / venue / visibility state. Paired CIs for close calls. Link raw JSON/CSV.>

## Decision
keep | revert | need data — and the next experiment.

## Test results
<Unit / parity tests run for this change, with counts.>
```
