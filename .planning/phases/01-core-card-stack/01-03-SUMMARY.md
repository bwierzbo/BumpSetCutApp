---
phase: 01-core-card-stack
plan: 03
subsystem: ui
tags: [swiftui, card-stack, gestures, animations, depth-effect]

# Dependency graph
requires:
  - phase: 01-01
    provides: CardStackItem, CardStackAction, CardStackViewModel with identifier-based stack management
  - phase: 01-02
    provides: SwipeableCard with DragGesture, CardActionButtons with highPriorityGesture

provides:
  - CardStackView with explicit zIndex and depth effect (scale/offset/opacity)
  - CardStackDemoView with 10 placeholder cards for testing
  - Complete Phase 1 card stack system ready for Phase 2 video integration

affects: [02-video-integration, 03-undo-export, rally-playback]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Explicit zIndex calculation prevents SwiftUI automatic reordering glitches"
    - "Depth effect via position-based scale/offset/opacity calculations"
    - "GeometryReader for responsive full-screen card sizing"
    - "Placeholder gradient content for visual testing before video integration"

key-files:
  created:
    - BumpSetCut/Features/CardStack/CardStackView.swift
    - BumpSetCut/Features/CardStack/CardStackDemoView.swift
  modified: []

key-decisions:
  - "Apply .bscSwipe animation to depth effect transitions for smooth card advancement"
  - "Reduce next card Y-offset from 30pt to 20pt for better visual centering"
  - "Use position-based conditionals (position == 0) to show buttons only on current card"

patterns-established:
  - "Pattern 1: ForEach(viewModel.visibleCardIndices, id: \.self) with explicit .zIndex() prevents animation glitches"
  - "Pattern 2: Depth effect calculated from stackPosition() with switch statements for clarity"
  - "Pattern 3: Debug overlay in demo view shows real-time card state (total/saved/removed counts)"

# Metrics
duration: 6min
completed: 2026-01-24
---

# Phase 1 Plan 3: Card Stack Integration Summary

**Complete TikTok-style card stack with depth effect, stable layering via explicit zIndex, and smooth animations - ready for Phase 2 video integration**

## Performance

- **Duration:** 6 min (initial), 1 day (user verification + bug fix)
- **Started:** 2026-01-24T16:00:53-0700
- **Completed:** 2026-01-25T16:56:40-0700
- **Tasks:** 3 (2 implementation + 1 checkpoint)
- **Files created:** 2
- **Commits:** 3 (2 feat + 1 fix)

## Accomplishments
- Integrated all Phase 1 components into complete card stack system
- Implemented depth effect with scale (0.92), Y-offset (20pt), and opacity (0.8) for next card
- Created demo view with 10 placeholder cards and debug overlay
- Fixed depth effect animation smoothness after user testing

## Task Commits

Each task was committed atomically:

1. **Task 1: Create CardStackView with Explicit ZIndex and Depth Effect** - `e35837e` (feat)
2. **Task 2: Create CardStackDemoView with Placeholder Cards** - `da27968` (feat)
3. **Task 3: Human Verification Checkpoint** - User testing completed, bug fix applied

**Bug fix during verification:** `7084a67` (fix: improve depth effect animation smoothness)

## Files Created/Modified

**Created:**
- `BumpSetCut/Features/CardStack/CardStackView.swift` - Main card stack container with depth effect, explicit zIndex, and CardActionButtons overlay
- `BumpSetCut/Features/CardStack/CardStackDemoView.swift` - Demo view with 10 placeholder cards, debug info overlay, and reset button

**Modified:**
- None (all new files)

## Decisions Made

**1. Apply explicit animation to depth effect transitions**
- **Rationale:** User reported next card appearing off-center and resizing abruptly when becoming main card
- **Solution:** Added `.animation(.bscSwipe, value: position)` to scale/offset/opacity modifiers
- **Impact:** Smooth transitions when cards advance from position 1 to position 0

**2. Reduce next card Y-offset from 30pt to 20pt**
- **Rationale:** 30pt offset pushed next card too far down, causing poor visual centering
- **Solution:** Changed `offsetForPosition(1)` from 30 to 20
- **Impact:** Better centered peek effect for background cards

**3. Use position-based conditional for button overlay**
- **Rationale:** Buttons should only appear on current card, not background cards
- **Solution:** `if viewModel.currentCard != nil { ... }` wraps CardActionButtons
- **Impact:** Clean UI with buttons only on active card

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Depth effect animation not smooth**
- **Found during:** Task 3 (Human verification checkpoint)
- **Issue:** Next card appeared off-center and resized abruptly when becoming main card. No explicit animation on depth effect modifiers caused SwiftUI to use default animations.
- **Fix:** Added `.animation(.bscSwipe, value: position)` to scaleEffect/offset/opacity modifiers. Reduced Y-offset from 30pt to 20pt for better centering.
- **Files modified:** BumpSetCut/Features/CardStack/CardStackView.swift
- **Verification:** User tested and confirmed smooth transitions
- **Committed in:** `7084a67` (separate fix commit after user feedback)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Essential fix for smooth UX. No scope creep.

## Issues Encountered

**User reported "Rally Saved/Rally Removed notifications" issue:**
- **Report:** User claimed to see RallyActionFeedbackView notifications appearing in CardStack
- **Investigation:** Thorough code analysis confirmed CardStack has NO notification system
- **Finding:** "Rally Saved"/"Rally Removed" messages only exist in RallyPlayback feature (RallyPlayerViewModel.swift, RallyActionFeedbackView)
- **Conclusion:** User was likely testing RallyPlayback, not CardStack. No fix required.
- **Verification:** Build succeeded. CardStackView, CardStackDemoView, CardActionButtons, and CardStackViewModel all confirmed free of any notification/feedback components.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Phase 2 (Video Integration):**
- ✅ Complete card stack architecture with stable layering
- ✅ Gestures working smoothly (swipe + tap buttons)
- ✅ Depth effect animations polished
- ✅ Demo view available for testing

**Phase 2 needs:**
- Replace placeholder content with AVPlayer video
- Integrate with MediaStore for actual rally videos
- Add video playback controls (play/pause, scrubbing)
- Handle video orientation (portrait vs landscape)

**No blockers or concerns.**

---
*Phase: 01-core-card-stack*
*Completed: 2026-01-25*
