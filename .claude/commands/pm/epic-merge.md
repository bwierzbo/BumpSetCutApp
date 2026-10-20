---
allowed-tools: Bash, Read, Write
---

# Epic Merge

Finish a completed epic by opening a pull request from its worktree branch to main. **This command does not merge and does not push `main`** (decision D-005/D-014, `docs/workflow/WORKING_AGREEMENT.md`): Codex reviews the PR and the owner merges. Cleanup runs only after the owner has merged.

## Usage
```
/pm:epic-merge <epic_name>
```

## Quick Check

1. **Verify worktree exists:**
   ```bash
   git worktree list | grep "epic-$ARGUMENTS" || echo "❌ No worktree for epic: $ARGUMENTS"
   ```

2. **Check for active agents:**
   Read `.claude/epics/$ARGUMENTS/execution-status.md`
   If active agents exist: "⚠️ Active agents detected. Stop them first with: /pm:epic-stop $ARGUMENTS"

## Instructions

### 1. Pre-Merge Validation

Navigate to worktree and check status:
```bash
cd ../epic-$ARGUMENTS

# Check for uncommitted changes
if [[ $(git status --porcelain) ]]; then
  echo "⚠️ Uncommitted changes in worktree:"
  git status --short
  echo "Commit or stash changes before merging"
  exit 1
fi

# Check branch status
git fetch origin
git status -sb
```

### 2. Run Tests (Optional but Recommended)

```bash
# Look for test commands
if [ -f package.json ]; then
  npm test || echo "⚠️ Tests failed. Continue anyway? (yes/no)"
elif [ -f Makefile ]; then
  make test || echo "⚠️ Tests failed. Continue anyway? (yes/no)"
fi
```

### 3. Update Epic Documentation

Get current datetime: `date -u +"%Y-%m-%dT%H:%M:%SZ"`

Update `.claude/epics/$ARGUMENTS/epic.md`:
- Set status to "completed"
- Update completion date
- Add final summary

Commit it in the worktree so the rebase in step 4 starts from a clean tree (`rebase.autoStash` is off by default):
```bash
cd ../epic-$ARGUMENTS
git add .claude/epics/$ARGUMENTS/epic.md
git commit -m "Epic $ARGUMENTS: mark completed"
[[ -z $(git status --porcelain) ]] || { echo "❌ Worktree still dirty after committing epic.md:"; git status --short; exit 1; }
```

### 4. Rebase onto main and push the branch

```bash
cd ../epic-$ARGUMENTS
git fetch origin
git rebase origin/main || {
  echo "❌ Conflicts rebasing epic/$ARGUMENTS onto main — resolve in the worktree (git status; edit; git add; git rebase --continue), then rerun."
  exit 1
}
git push --force-with-lease -u origin epic/$ARGUMENTS
```

### 5. Open the pull request (do not merge)

Fill `.github/PULL_REQUEST_TEMPLATE.md` with real evidence (scope, acceptance criteria, build/test output, risks, docs). `--fill` would skip the template, so pass the filled file:

```bash
body=$(mktemp)
# write the filled template to $body, listing the epic's completed tasks:
#   $(cd .claude/epics/$ARGUMENTS && ls *.md | grep -E '^[0-9]+' | while read f; do echo "- $(grep '^name:' $f | cut -d: -f2)"; done)
# and "Closes #<epic issue>" from .claude/epics/$ARGUMENTS/epic.md
gh pr create --base main --head epic/$ARGUMENTS --title "Epic: $ARGUMENTS" --body-file "$body"
```

Codex reviews the PR when it opens. Address every finding on the branch (push, then comment `@codex review`). **Stop here.** The owner merges.

### 6. After the owner has merged — cleanup

Run only once `gh pr view <n> --json state --jq .state` prints `MERGED`:
```bash
cd {main-repo-path}
git checkout main
git pull origin main

git worktree remove ../epic-$ARGUMENTS
echo "✅ Worktree removed: ../epic-$ARGUMENTS"
git branch -d epic/$ARGUMENTS
git push origin --delete epic/$ARGUMENTS 2>/dev/null || true

mkdir -p .claude/epics/archived/
mv .claude/epics/$ARGUMENTS .claude/epics/archived/
echo "✅ Epic archived: .claude/epics/archived/$ARGUMENTS"
```

### 7. Update GitHub Issues (after merge)

Task issues close via `Closes #n` in the PR body when the owner merges. Close any that did not:
```bash
for task_file in .claude/epics/archived/$ARGUMENTS/[0-9]*.md; do
  issue_num=$(grep 'github:' $task_file | grep -oE '[0-9]+$')
  if [ ! -z "$issue_num" ]; then
    gh issue close $issue_num -c "Completed in epic $ARGUMENTS (PR merged by owner)" 2>/dev/null || true
  fi
done
```

### 8. Final Output

At the review gate (the normal stopping point):
```
✅ Epic ready for review: $ARGUMENTS

  PR: {url}
  Branch: epic/$ARGUMENTS → main (rebased on origin/main)
  Commits: {count} · Files changed: {count}

Next: Codex reviews; address findings; the owner merges. Then run step 6 cleanup.
```

## Important Notes

- Always check for uncommitted changes first
- Run tests before opening the PR when possible
- Never `git merge` into main or `git push origin main` from this command; the owner merges the PR (D-005/D-014)
- Archive epic data instead of deleting
- Close GitHub issues to maintain sync