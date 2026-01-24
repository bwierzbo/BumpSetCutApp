---
phase: 01-core-card-stack
plan: 01
subsystem: ui
tags: [swiftui, observable, card-stack, gestures, identifiable]

# Dependency graph
requires:
  - phase: none
    provides: "Initial project setup with RallyPlayerViewModel pattern"
provides:
  - Generic CardStackItem model with UUID-based Identifiable tracking
  - CardStackAction enum for user decisions (save/remove)
  - CardStackViewModel with @Observable pattern and visible stack management
  - Explicit zIndex calculation preventing animation glitches
  - Position-based visibility logic for rendering optimization
affects: [02-swipeable-cards, 03-placeholder-content, 04-gesture-actions, 05-undo-system]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@Observable view model pattern (iOS 17+)"
    - "Identifier-based card tracking via Identifiable protocol"
    - "Explicit zIndex calculation for stable layering"
    - "Visible indices optimization for rendering performance"

key-files:
  created:
    - BumpSetCut/Features/CardStack/Models/CardStackItem.swift
    - BumpSetCut/Features/CardStack/Models/CardStackAction.swift
    - BumpSetCut/Features/CardStack/CardStackViewModel.swift
  modified: []

key-decisions:
  - "Use Identifiable protocol with stable UUID for card tracking (prevents animation glitches during state changes)"
  - "Implement explicit zIndex calculation based on stack position (prevents SwiftUI automatic reordering bugs)"
  - "Store action state on card items rather than separate tracking structure (simpler state management)"
  - "Use @Observable macro instead of @ObservableObject (iOS 17+, better performance)"

patterns-established:
  - "Pattern 1: Stack position calculation returns relative position (-1/0/1+) for transforms and zIndex"
  - "Pattern 2: Visible indices array updated on navigation for efficient rendering (current + 2 ahead + 1 behind)"
  - "Pattern 3: Generic content property placeholder for Phase 2 video URL integration"

# Metrics
duration: 5min
completed: 2026-01-24
---

# Phase 01 Plan 01: Core Card Stack Summary

**Generic card stack data models with identifier-based tracking and @Observable state management for swipeable TikTok-style UI**

## Performance

- **Duration:** 5 min
- **Started:** 2026-01-24T22:39:24Z
- **Completed:** 2026-01-24T22:44:22Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created generic CardStackItem model with stable UUID identification preventing animation bugs
- Implemented CardStackAction enum for save/remove user decisions
- Built CardStackViewModel following existing RallyPlayerViewModel pattern with @Observable macro
- Established explicit zIndex calculation preventing SwiftUI layering glitches
- Set up visible indices optimization reducing render overhead

## Task Commits

Each task was committed atomically:

1. **Task 1: Create CardStackItem and CardStackAction Models** - `e23992a` (feat)
2. **Task 2: Create CardStackViewModel with Identifier-Based Stack Management** - `28c6d58` (feat)

## Files Created/Modified
- `BumpSetCut/Features/CardStack/Models/CardStackItem.swift` - Generic Identifiable card with UUID, content, and action tracking
- `BumpSetCut/Features/CardStack/Models/CardStackAction.swift` - Enum for save/remove actions with Equatable conformance
- `BumpSetCut/Features/CardStack/CardStackViewModel.swift` - @Observable state manager with visible stack logic, position calculation, and explicit zIndex

## Decisions Made

**Decision 1: Identifier-based tracking**
- Use Identifiable protocol with stable UUID instead of array indices
- Rationale: Prevents animation glitches when cards are added/removed (research Pattern 1)
- Impact: SwiftUI tracks cards by ID, animations remain stable during state changes

**Decision 2: Explicit zIndex calculation**
- Implement zIndexForPosition method returning explicit values (100 for current, negative for others)
- Rationale: Without explicit zIndex, SwiftUI reorders views during animations causing layering bugs (research Pitfall 1)
- Impact: Stable card layering during swipe animations

**Decision 3: Generic content property**
- Use String placeholder for content instead of video URL types
- Rationale: Maintains separation of concerns - Phase 2 will add video-specific logic
- Impact: CardStack feature is reusable for any content type, not coupled to video playback

**Decision 4: Store action on card items**
- Add optional action property directly on CardStackItem
- Rationale: Simpler than separate tracking structure, matches existing RallyPlayerViewModel pattern
- Impact: Single source of truth for card state

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Phase 2 (Swipeable Cards):**
- CardStackViewModel provides all state management needed for gesture handling
- Identifiable protocol ensures stable animations during swipes
- zIndexForPosition method ready for card layering in views
- visibleCardIndices optimization reduces rendering overhead
- Generic design allows Phase 2 to focus solely on UI/gesture implementation

**No blockers or concerns**

---
*Phase: 01-core-card-stack*
*Completed: 2026-01-24*
