<!-- Fill every section. "n/a" is fine when justified; empty is not. See docs/workflow/WORKING_AGREEMENT.md -->

## Scope

<!-- One paragraph: what this PR changes and why. Link the decision(s) and roadmap phase it serves. -->

- Decision(s): <!-- e.g. D-005 -->
- Roadmap phase / task: <!-- e.g. Phase 2 — scorecard; Task A -->
- Issue(s): <!-- #123, or n/a -->
- Experiment ID(s): <!-- EXP-20261020-example, or n/a -->

## Acceptance criteria

<!-- Measurable. Copy from the task definition; tick what this PR meets. -->

- [ ]
- [ ]

## Validation evidence

<!-- Paste or link actual output. "Tests pass" without output does not count. -->

| Check | Result | Evidence |
|---|---|---|
| `scripts/build.sh both` (or `auto`) | | |
| Unit tests (`BumpSetCutTests`) | | |
| Scoring / replay parity tests (if scoring, replay, builder or decider touched) | | |
| Headless RallyLab run (if pipeline or data code touched) | | |
| Physical iPhone (if processing code touched) | | |

Dataset / split / model versions used (if any): <!-- manifest sha, split id, model sha — from EXPERIMENT_REGISTRY.md -->

## Affected files

<!-- Grouped: created / modified / deleted. Call out shared-pipeline files (dual-target rule). -->

## Assumptions and limitations

<!-- What was assumed, what was not verified, what is deliberately out of scope. -->

## Risks and rollback

<!-- Behaviour changes a user or the pipeline could see; how to revert. "None" needs a sentence of why. -->

## Documentation

- [ ] Decision log updated (`docs/decisions/DECISION_LOG.md`) or n/a
- [ ] Experiment registry updated (`docs/ml-roadmap/EXPERIMENT_REGISTRY.md`) or n/a
- [ ] `CLAUDE.md` / rules updated or n/a
- [ ] Docs index (`docs/README.md`) links any new document

## Outstanding issues

<!-- Known gaps the reviewer should weigh, and anything that conflicts with an existing rule. -->

## Confirmation

- [ ] No detector, training or production-processing code changed **or** the change is described above with evidence.
- [ ] This PR stops at the review gate; it will not be merged by the author.
