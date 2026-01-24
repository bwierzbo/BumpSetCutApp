---
phase: 01-core-card-stack
plan: 02
subsystem: ui
tags: [swiftui, gestures, animations, drag-gesture, card-stack]

# Dependency graph
requires:
  - phase: 01-01
    provides: "CardStackViewModel with @Observable pattern and zIndex management"
provides:
  - SwipeableCard component with DragGesture and velocity detection
  - CardActionButtons with highPriorityGesture for tap handling
  - Spring animation integration using AnimationTokens
  - Gesture conflict resolution pattern (highPriorityGesture)
  - Generic content wrapper for flexible card content
affects: [03-placeholder-content, 04-gesture-actions, 05-undo-system]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "DragGesture with velocity AND translation thresholds (300 pts/sec, 120 pts)"
    - "Card rotation during drag using clamped calculation (±15 degrees)"
    - "Spring animations with .bscSnappy and .bscQuick from AnimationTokens"
    - "highPriorityGesture on buttons to prevent parent gesture interference"
    - "Generic content via @ViewBuilder for flexible card composition"

key-files:
  created:
    - BumpSetCut/Features/CardStack/Components/SwipeableCard.swift
    - BumpSetCut/Features/CardStack/Components/CardActionButtons.swift
  modified: []

key-decisions:
  - "Use velocity (>300 pts/sec) OR translation (>120 pts) thresholds for natural swipe feel across device sizes"
  - "Apply highPriorityGesture to buttons to prevent drag gesture consuming tap events (research Pitfall 2)"
  - "Clamp rotation to ±15 degrees during drag for balanced visual feedback"
  - "Generic content parameter via @ViewBuilder enables Phase 3 to swap placeholder for video content"

patterns-established:
  - "Pattern 1: Velocity-based gesture detection using DragGesture.Value.velocity for natural iOS feel"
  - "Pattern 2: Spring animations from AnimationTokens for consistent app-wide motion design"
  - "Pattern 3: Gesture precedence using highPriorityGesture for button/drag conflict resolution"

# Metrics
duration: 6min
completed: 2026-01-24
---

# Phase 01 Plan 02: Swipeable Cards Summary

**DragGesture-based swipeable card with velocity detection (>300 pts/sec), rotation feedback (±15°), and highPriorityGesture buttons preventing tap/drag conflicts**

## Performance

- **Duration:** 6 min
- **Started:** 2026-01-24T22:47:35Z
- **Completed:** 2026-01-24T22:53:30Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Created SwipeableCard component accepting generic content via @ViewBuilder with DragGesture handling
- Implemented velocity (>300 pts/sec) AND translation (>120 pts) threshold detection for natural swipe feel
- Added card rotation during drag (±15 degrees) for visual feedback matching iOS system gestures
- Built CardActionButtons with heart/trash SF Symbols using highPriorityGesture to prevent drag interference
- Integrated spring animations from AnimationTokens (.bscSnappy, .bscQuick) for consistent motion design

## Task Commits

Each task was committed atomically:

1. **Task 1: Create SwipeableCard with DragGesture and Velocity Detection** - `428da97` (feat)
2. **Task 2: Create CardActionButtons with Gesture Precedence** - `0e2d014` (feat)

## Files Created/Modified
- `BumpSetCut/Features/CardStack/Components/SwipeableCard.swift` - Generic swipeable card with DragGesture, velocity detection, rotation feedback, spring animations
- `BumpSetCut/Features/CardStack/Components/CardActionButtons.swift` - Heart (save) and trash (remove) buttons with highPriorityGesture and press feedback

## Decisions Made

**Decision 1: Velocity AND translation thresholds**
- Use both velocity (>300 pts/sec) AND translation (>120 pts) checks for swipe detection
- Rationale: Research Pattern 2 shows velocity-only fails on slow drags, translation-only feels sticky on fast flicks
- Impact: Natural swipe feel across all device sizes and user interaction speeds

**Decision 2: highPriorityGesture on buttons**
- Apply `.highPriorityGesture(TapGesture())` to both action buttons
- Rationale: Without it, parent DragGesture consumes tap events (research Pitfall 2)
- Impact: Buttons remain tappable without triggering drag, prevents user frustration

**Decision 3: Generic content via @ViewBuilder**
- SwipeableCard accepts any content through generic @ViewBuilder parameter
- Rationale: Keeps card stack feature reusable, allows Phase 3 to provide placeholder content without modifying SwipeableCard
- Impact: Clean separation of concerns, component remains flexible for future uses

**Decision 4: Clamped rotation (±15 degrees)**
- Use `max(-15, min(15, rotationAmount))` to limit drag rotation
- Rationale: Research shows excessive rotation feels unstable, 10-15° provides feedback without distraction
- Impact: Balanced visual feedback during drag

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Phase 3 (Placeholder Content):**
- SwipeableCard accepts generic content via @ViewBuilder - ready for placeholder injection
- DragGesture properly handles velocity and translation detection - swipe interactions complete
- CardActionButtons provide alternative action mechanism with proper gesture precedence
- Spring animations use existing AnimationTokens - motion design consistent with app
- All research patterns implemented correctly (velocity detection, highPriorityGesture, rotation clamping)

**Critical blocker RESOLVED:**
- Research blocker "Phase 1 must address gesture conflicts between card swipe and tap actions" RESOLVED via highPriorityGesture implementation (Pitfall 2)

**No new blockers or concerns**

---
*Phase: 01-core-card-stack*
*Completed: 2026-01-24*
