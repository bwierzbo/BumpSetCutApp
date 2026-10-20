---
name: chatgpt-review
status: proposed
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
---

# Handing a pull request to ChatGPT for review

ChatGPT has no write access and no GitHub integration in this workflow. The owner carries the PR to ChatGPT and carries the findings back. Everything ChatGPT needs is in three artefacts: the PR description, the diff, and the documents the PR links.

## 1. Export the PR

From the repo on the Mac, with the PR number `N`:

```bash
mkdir -p ~/Downloads/pr-review && cd ~/Downloads/pr-review
gh pr view N --json number,title,body,headRefName,baseRefName,commits,files \
  --jq '"# PR #\(.number): \(.title)\n\nbranch: \(.headRefName) → \(.baseRefName)\nhead: \(.commits[-1].oid)\n\n\(.body)\n\n## Files\n" + ([.files[] | "- \(.path) (+\(.additions)/-\(.deletions))"] | join("\n"))' > pr-N.md
gh pr diff N > pr-N.diff
wc -l pr-N.diff
```

If the diff is over roughly 1,500 lines, ask the implementer to split the PR before review. Large generated or copied files (for example a roadmap copy) can be excluded from the diff and listed by name instead:

```bash
gh pr diff N -- . ':!docs/ml-roadmap/ROADMAP_REVISED_2026-10-20.md' > pr-N.diff
```

Also export any document the PR description links that ChatGPT would need to judge it (decision log entries, the baseline report, a registry entry):

```bash
cp docs/decisions/DECISION_LOG.md docs/ml-roadmap/BASELINE.md ~/Downloads/pr-review/
```

## 2. Give ChatGPT the review brief

Attach `pr-N.md`, `pr-N.diff` and the exported docs, then paste:

> You are the independent reviewer for this pull request in the BumpSetCut / RallyLab repository. The working agreement is in WORKING_AGREEMENT.md; the current decisions are in DECISION_LOG.md; the plan is ROADMAP_REVISED_2026-10-20.md. Review the PR description and the diff against:
> 1. **Scope** — does the change do what the stated task and acceptance criteria say, nothing more, nothing less?
> 2. **Correctness** — bugs, edge cases, broken invariants (metadata-only processing, shared pipeline between iOS and RallyLab, raw vs padded scoring, leakage between splits, label provenance).
> 3. **Evidence** — is the validation evidence actually present and sufficient for the review gates in the working agreement? Flag claims without output.
> 4. **Decisions** — does anything contradict a logged decision or the roadmap without a new decision being proposed?
> 5. **Documentation** — are the decision log, experiment registry, CLAUDE.md and docs index updated where the agreement requires it?
>
> Return findings as a numbered list. For each: severity (blocker / should-fix / nit), file and line or section, what is wrong, and the concrete change you want. End with a verdict: **approve**, **approve after fixes**, or **request changes**, and list any questions for the owner. Do not restate the PR; only report findings.

## 3. Bring the findings back

Post the findings on the PR so they are part of the record:

```bash
gh pr comment N --body-file ~/Downloads/pr-review/findings-N.md
```

Or paste them into the Claude Code session with "review findings for PR #N:". The implementer must address **every** finding: a fix commit, or a written reason in the PR for not changing it. It then replies on the PR summarising what changed per finding.

## 4. Re-review and merge

Repeat steps 1 to 3 for a further round if the verdict was "request changes" or the fixes were non-trivial. When the verdict is approve and the owner agrees, the owner merges (squash or merge commit, owner's choice) and deletes the branch. The implementer never merges unless told "merge PR #N" for that specific PR.

## Findings format (for the record)

```
1. [blocker] RallyLab/RallyCutScore.swift:41 — padded clips scored as raw boundaries; preroll counts as −2 s start error. Fix: score BuiltSegment.raw here, padded in a separate export scorecard.
2. [should-fix] docs/decisions/DECISION_LOG.md D-007 — gate threshold stated as a number without a source. Fix: mark "to be measured" and link the evaluation that will set it.
3. [nit] ...
Verdict: approve after fixes. Questions for owner: none.
```
