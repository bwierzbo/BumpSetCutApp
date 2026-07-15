# .claude/CLAUDE.md

Additional guidance for Claude Code in this repository.

## Behavior

- Be concise and skeptical
- Ask questions when intent is unclear
- Point out better approaches when they exist
- No flattery or unnecessary compliments
- **Default to momentum**: when work items are enumerated (sprints, findings, optimizations), batch and do all of them rather than asking which to do — the user's answer is consistently "keep going / do all". Reserve questions for genuine product decisions, and give the design rationale/trade-offs when asking.
- **Fix ALL review findings** (code review, cloud review, advisors) — never triage some as deferred/not-mine without asking first.
- **Push after every commit chunk**, before starting the next work item. Work sometimes spans two repos (BumpSetCut + BumpSetCutWebApp) — confirm which repo(s) to push when both changed; the user sometimes pushes the webapp himself.
- **Security warnings about user-pasted secrets: state once, then proceed.** Don't repeat the warning in later turns.
- Commit a checkpoint before risky bulk changes (dead-code sweeps, large deletions).

## Git

- ANY file referenced by project.pbxproj (models, assets) must be committed in the same commit as the pbxproj change — local-only files break Xcode Cloud silently.
- Follow the memory/CLAUDE.md dual-target rule before declaring shared-pipeline changes done.

## Absolute Rules

- NO partial implementation or "simplified for now" placeholders
- NO code duplication - read existing code before writing new functions
- NO dead code - delete unused code completely
- NO over-engineering - simple functions over unnecessary abstractions
- NO resource leaks - clean up file handles, observers, timers

## Technical Notes

### Video Processing
- `enableEnhancedPhysics` is currently disabled in ProcessorConfig due to overly strict validation
- Videos are blocked from reprocessing via `canBeProcessed` computed property
- Debug data stored in `.debug_data` directory with UUID-based naming

### Data Integrity
- Use `decodeIfPresent` for new Codable fields to maintain backwards compatibility
- When adding relationships, implement cleanup methods (see `cleanupProcessedVideoRelationships`)
- MediaStore posts `.libraryContentChanged` notification after any manifest save

### UI Patterns
- Use both min/max height constraints for consistent grid sizing
- Calculate orientation once per view update and reuse
- Use LazyVGrid/LazyVStack for large collections
