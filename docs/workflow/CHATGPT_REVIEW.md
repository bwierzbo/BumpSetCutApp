---
name: independent-review
status: accepted (D-005, D-014)
created: 2026-10-20T22:12:44Z
updated: 2026-10-21T01:10:00Z
---

# Independent review: Codex on GitHub, and the manual ChatGPT export

Codex is the independent reviewer for pull requests ([D-014](../decisions/DECISION_LOG.md#d-014)). It runs as the GitHub app `chatgpt-codex-connector`, reads `AGENTS.md` for its repository instructions, and has no merge authority. The manual export below is the fallback when the owner wants a review outside GitHub (a ChatGPT conversation, a second opinion, or a PR Codex cannot see).

## 1. Codex on GitHub (primary)

**Triggers.** Codex reviews when a PR is opened for review, when a draft is marked ready, or when someone comments `@codex review` (or `@codex security review`). After pushing fix commits, comment `@codex review` to get the new head reviewed; Codex records the commit it reviewed.

**Where findings appear.** As inline review comments on the diff, each with a priority badge (`P1`, `P2`, …) and a one-line title, plus a "Codex Review Summary" comment that tracks state. A 👍 reaction with no comments means no findings.

**Retrieving them from the terminal** (what the implementer runs):

```bash
N=65
gh pr view $N --json reviews --jq '.reviews[] | "--- \(.author.login) \(.state) \(.submittedAt)\n\(.body)"'
gh api repos/bwierzbo/BumpSetCutApp/pulls/$N/comments --jq '.[] | "--- \(.user.login) \(.path):\(.line // .original_line)\n\(.body)\n"'
```

**Responding.** One fix commit per finding where practical, pushed to the branch. Then one PR comment listing each finding and what was done (fixed with commit, or reason for no change). Blocking findings (P0/P1, or "Blocking defect" in `AGENTS.md` terms) are either fixed or explicitly accepted by the owner in a PR comment; the implementer never accepts one on the owner's behalf. Then `@codex review` for the re-check.

## 2. Manual export for ChatGPT (fallback)

ChatGPT has no repository access, so the export must carry the context a reviewer would otherwise click through: the PR description, base and head commits, the diff, the **full post-change contents of every changed file** (a diff hunk alone hides surrounding code and prose), and the repository documents the review rules refer to. The commands below were run against PR #65 on 2026-10-20 with `gh` 2.60.0 and `git` 2.x; they use `git` for the diff because `gh pr diff` takes no pathspec and the installed version has no `--exclude` flag.

```bash
N=65                                   # the PR number
out=~/Downloads/pr-review/pr-$N; rm -rf "$out"; mkdir -p "$out/files"
cd ~/Code/BumpSetCut

# Base and head exactly as GitHub sees them
git fetch origin main "pull/$N/head:refs/remotes/origin/pr/$N"
base=$(git merge-base origin/main origin/pr/$N)
head=$(git rev-parse origin/pr/$N)
printf 'PR #%s\nbase %s\nhead %s\n' "$N" "$base" "$head" > "$out/REFS.txt"

# 1. Description as posted, and the file list
gh pr view $N --json body --jq .body > "$out/pr-$N.md"
git diff "$base" "$head" --stat > "$out/pr-$N.stat"

# 2. Diff, excluding files that are verbatim owner texts (list them in REFS.txt instead)
git diff "$base" "$head" -- . \
  ':(exclude)docs/ml-roadmap/ROADMAP_REVISED_2026-10-20.md' \
  ':(exclude)docs/decisions/2026-10-20-phase0-owner-decisions.md' > "$out/pr-$N.diff"

# 3. Whole post-change files for everything the PR touches
git diff --name-only "$base" "$head" | while read -r f; do
  mkdir -p "$out/files/$(dirname "$f")"
  git show "$head:$f" > "$out/files/$f" 2>/dev/null || echo "(deleted in PR)" > "$out/files/$f"
done

# 4. Repository context the reviewer must read alongside the diff
for f in AGENTS.md docs/workflow/WORKING_AGREEMENT.md docs/decisions/DECISION_LOG.md; do
  git show "$head:$f" > "$out/context-$(basename "$f")"
done

wc -l "$out/pr-$N.diff"; ls "$out"
```

If the diff is over roughly 1,500 lines, ask the implementer to split the PR before review. Attach the whole `pr-$N` folder (or zip it) to ChatGPT with the brief below. Adjust the `:(exclude)` paths per PR; they are a git pathspec, so `':(exclude)docs/**/*.generated.md'` style globs work too.

### The brief to paste

> You are the independent reviewer for this pull request in the BumpSetCut / RallyLab repository. Your repository instructions are `context-AGENTS.md`; the working agreement is `context-WORKING_AGREEMENT.md`; the current decisions are `context-DECISION_LOG.md`. `REFS.txt` gives the base and head commits; `pr-N.md` is the PR description; `pr-N.diff` is the diff; `files/` holds the full post-change contents of every changed file. Review against the eight high-value rules in `AGENTS.md` and the review gates in the working agreement. Distinguish what the evidence shows from what the description claims. Return findings in the `AGENTS.md` output format (severity, location, evidence, action) and end with a verdict: **approve**, **approve after fixes**, or **request changes**, plus any questions for the owner. Do not restate the PR.

### Bringing findings back

```bash
gh pr comment $N --body-file ~/Downloads/pr-review/pr-$N/findings.md
```

or paste them into the Claude Code session as "review findings for PR #N:". The implementer then follows the same respond-and-re-review steps as for Codex.

## 3. Merge

When the verdict is approve, every blocking finding is fixed or explicitly accepted by the owner, and the owner agrees, the owner merges (squash or merge commit, owner's choice) and deletes the branch. The implementer never merges unless told "merge PR #N" for that specific PR.
