# .claude/CLAUDE.md

Additional guidance for Claude Code in this repository.

## Behavior

- Be concise and skeptical
- Ask questions when intent is unclear
- Point out better approaches when they exist
- No flattery or unnecessary compliments

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
