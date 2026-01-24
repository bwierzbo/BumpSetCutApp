# Roadmap: BumpSetCut Rally Viewer Refinement

## Overview

This roadmap transforms the existing rally playback interface into a polished Tinder-style card stack with swipe gestures, auto-playing video, and batch export capabilities. The journey progresses from foundational gesture/animation architecture (Phase 1), through video playback integration (Phase 2), production-ready state management (Phase 3), end-to-end export workflow (Phase 4), to final polish features (Phase 5). Each phase builds on validated foundations, with critical architectural decisions (gesture conflicts, memory management, zIndex stability) addressed early to prevent retrofitting.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Core Card Stack** - Swipeable card stack with gesture system and animations (no video)
- [ ] **Phase 2: Video Playback Integration** - Auto-play video with orientation handling and memory management
- [ ] **Phase 3: State Management & Persistence** - Undo, state persistence, and lifecycle handling
- [ ] **Phase 4: Batch Export & Selection** - Checkbox selection with individual/stitched export workflow
- [ ] **Phase 5: Polish & Advanced Features** - Page-peel animation, haptics, and threshold tuning

## Phase Details

### Phase 1: Core Card Stack
**Goal**: Users can swipe through placeholder cards with smooth gestures and spring animations
**Depends on**: Nothing (first phase)
**Requirements**: CARD-01, CARD-02, CARD-03, CARD-04, CARD-05, CARD-06, CARD-08
**Success Criteria** (what must be TRUE):
  1. User sees stacked card layout with depth effect (scale and offset on rear cards)
  2. User can drag cards left or right with finger, card follows drag smoothly
  3. Cards animate with spring physics when released (bounce and settle)
  4. Card stack maintains stable layering during all animations (no jumping or z-index glitches)
  5. User can tap heart button or trash button as alternative to swiping
**Plans**: 3 plans

Plans:
- [ ] 01-01-PLAN.md — Generic card stack models and state management
- [ ] 01-02-PLAN.md — Swipeable card component with gestures and action buttons
- [ ] 01-03-PLAN.md — Card stack view integration with depth effect and demo

### Phase 2: Video Playback Integration
**Goal**: Video auto-plays in cards with seamless looping and orientation-aware sizing
**Depends on**: Phase 1
**Requirements**: VIDEO-01, VIDEO-02, VIDEO-03, VIDEO-04, VIDEO-05, VIDEO-06, VIDEO-07, VIDEO-08
**Success Criteria** (what must be TRUE):
  1. Video auto-plays immediately when card is revealed
  2. Video loops seamlessly without visible restart or audio glitches
  3. Video pauses when card is swiped away
  4. Video fits screen in portrait mode without stretching (aspect ratio preserved)
  5. Video fills screen in landscape mode
  6. Video playback continues smoothly when device rotates between portrait and landscape
  7. Multiple video players managed without memory leaks or performance degradation
**Plans**: TBD

Plans:
- [ ] TBD

### Phase 3: State Management & Persistence
**Goal**: Actions persist across sessions with undo support and lifecycle handling
**Depends on**: Phase 2
**Requirements**: ACTION-01, ACTION-02, ACTION-03, ACTION-04, ACTION-05, ACTION-06, ACTION-07, ACTION-08
**Success Criteria** (what must be TRUE):
  1. Swiping right or tapping heart saves clip to "liked" collection
  2. Swiping left or tapping trash removes clip from stack (marked deleted)
  3. Heart button shows visual feedback when clip is liked (scale animation)
  4. Undo button appears after first action is taken
  5. User can tap undo to restore last action with reverse animation
  6. Undo button is disabled when no actions are available to undo
  7. Action buttons reposition to bottom in landscape mode without layout breakage
  8. Liked/deleted state persists if user backgrounds app and returns
**Plans**: TBD

Plans:
- [ ] TBD

### Phase 4: Batch Export & Selection
**Goal**: Users can select liked clips and export them individually or as stitched video
**Depends on**: Phase 3
**Requirements**: EXPORT-01, EXPORT-02, EXPORT-03, EXPORT-04, EXPORT-05, EXPORT-06, EXPORT-07, EXPORT-08, EXPORT-09, EXPORT-10, EXPORT-11, EXPORT-12, EMPTY-01, EMPTY-02, EMPTY-03, EMPTY-04
**Success Criteria** (what must be TRUE):
  1. User reaches export screen after swiping through all clips
  2. Export screen shows checkboxes for all liked clips
  3. User can toggle individual clip selection and see visual feedback
  4. Select all button checks all clips, deselect all unchecks all clips
  5. Export button is greyed out when no clips selected
  6. User can choose to export selected clips as individual files or single stitched video
  7. Export shows progress indicator during processing
  8. Success message confirms when export completes and videos are in camera roll
  9. Empty state appears when no clips liked with options to delete parent video or return home
**Plans**: TBD

Plans:
- [ ] TBD

### Phase 5: Polish & Advanced Features
**Goal**: Enhanced user experience with page-peel animation, haptic feedback, and tuning
**Depends on**: Phase 4
**Requirements**: CARD-07, POLISH-01, POLISH-02, POLISH-03, POLISH-04
**Success Criteria** (what must be TRUE):
  1. Cards show page-peel animation when swiped off stack (corner curls up)
  2. Haptic feedback triggers on swipe actions (left/right release)
  3. Haptic feedback triggers on button taps (heart/trash/undo)
  4. Swipe threshold feels responsive (40-50% card width triggers action)
  5. UI adapts smoothly to orientation changes without breaking layout or animations
**Plans**: TBD

Plans:
- [ ] TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Core Card Stack | 0/3 | Not started | - |
| 2. Video Playback Integration | 0/0 | Not started | - |
| 3. State Management & Persistence | 0/0 | Not started | - |
| 4. Batch Export & Selection | 0/0 | Not started | - |
| 5. Polish & Advanced Features | 0/0 | Not started | - |
