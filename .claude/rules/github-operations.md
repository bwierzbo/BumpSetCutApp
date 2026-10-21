# GitHub Operations Rule

Standard patterns for GitHub CLI operations.

## Authentication

**Don't pre-check authentication.** Just run the command and handle failure:

```bash
gh {command} || echo "❌ GitHub CLI failed. Run: gh auth login"
```

## Common Operations

### Get Issue Details
```bash
gh issue view {number} --json state,title,labels,body
```

### Create Issue
```bash
gh issue create --title "{title}" --body-file {file} --label "{labels}"
```

### Update Issue
```bash
gh issue edit {number} --add-label "{label}" --add-assignee @me
```

### Add Comment
```bash
gh issue comment {number} --body-file {file}
```

### Open a Pull Request
Fill `.github/PULL_REQUEST_TEMPLATE.md` with real evidence first; `--fill` uses commit messages and skips the template:
```bash
gh pr create --base main --head {branch} --title "{title}" --body-file {filled-template.md}
```
Never push to `main` and never merge **without explicit owner authorisation** for that specific change or PR ("merge PR #n", or a streamlined-tier authorisation quoted in the commit). Otherwise the owner merges after review (`docs/workflow/WORKING_AGREEMENT.md`).

## Error Handling

If any gh command fails:
1. Show clear error: "❌ GitHub operation failed: {command}"
2. Suggest fix: "Run: gh auth login" or check issue number
3. Don't retry automatically

## Important Notes

- Trust that gh CLI is installed and authenticated
- Use --json for structured output when parsing
- Keep operations atomic - one gh command per action
- Don't check rate limits preemptively
