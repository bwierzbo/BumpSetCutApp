# Requirements: BumpSetCut Rally Viewer Refinement

**Defined:** 2026-01-24
**Core Value:** Users can quickly review AI-detected rally clips with simple swipe gestures to keep the best moments and export them seamlessly.

## v1 Requirements

Requirements for rally viewer refinement. Each maps to roadmap phases.

### Card Stack Interface

- [ ] **CARD-01**: User sees rally clips in a stacked card layout with depth effect (scale + offset)
- [ ] **CARD-02**: User can swipe cards left or right with finger following drag
- [ ] **CARD-03**: Cards animate with spring physics on release (bounce/settle)
- [ ] **CARD-04**: Card stack maintains stable layering during swipe animations (no jumping/glitching)
- [ ] **CARD-05**: User can tap heart button at bottom-right as alternative to swipe right
- [ ] **CARD-06**: User can tap trash button at bottom-left as alternative to swipe left
- [ ] **CARD-07**: Cards show page-peel animation when swiped off stack
- [ ] **CARD-08**: Cards display visual feedback during drag (rotation, action hints)

### Video Playback

- [ ] **VIDEO-01**: Video auto-plays immediately when card is revealed
- [ ] **VIDEO-02**: Video loops seamlessly without visible restart
- [ ] **VIDEO-03**: Video pauses when card is swiped away
- [ ] **VIDEO-04**: Video fits screen in portrait mode without stretching
- [ ] **VIDEO-05**: Video fills screen in landscape mode
- [ ] **VIDEO-06**: Video playback continues smoothly during portrait/landscape rotation
- [ ] **VIDEO-07**: Multiple video players managed efficiently without memory leaks
- [ ] **VIDEO-08**: Single audio session prevents overlapping audio during swipes

### User Actions

- [ ] **ACTION-01**: Swipe right saves clip to "liked" collection
- [ ] **ACTION-02**: Swipe left removes clip from stack (marked deleted)
- [ ] **ACTION-03**: Heart button animates when clip is liked (swipe or tap)
- [ ] **ACTION-04**: Undo button appears after first action
- [ ] **ACTION-05**: User can undo last action with reverse peel animation
- [ ] **ACTION-06**: Undo restores previous card to top of stack
- [ ] **ACTION-07**: Undo button is disabled when no actions to undo
- [ ] **ACTION-08**: Action buttons reposition to bottom in landscape mode

### Export Workflow

- [ ] **EXPORT-01**: User reaches export screen after swiping through all clips
- [ ] **EXPORT-02**: Export screen shows checkboxes for all liked clips
- [ ] **EXPORT-03**: User can select/deselect individual clips for export
- [ ] **EXPORT-04**: Select all button checks all clips at once
- [ ] **EXPORT-05**: Deselect all button unchecks all clips at once
- [ ] **EXPORT-06**: Export button is greyed out when no clips selected
- [ ] **EXPORT-07**: User can export selected clips as individual files
- [ ] **EXPORT-08**: User can export selected clips as single stitched video
- [ ] **EXPORT-09**: Export shows confirmation dialog before starting
- [ ] **EXPORT-10**: Export shows progress indicator during processing
- [ ] **EXPORT-11**: Exported clips/video saved to camera roll
- [ ] **EXPORT-12**: Success message shown when export completes

### Empty States

- [ ] **EMPTY-01**: User sees notice when all clips deleted (no likes)
- [ ] **EMPTY-02**: Empty state offers option to delete parent video
- [ ] **EMPTY-03**: Empty state offers option to return to home screen
- [ ] **EMPTY-04**: User sees empty export screen when no clips liked

### Polish & Feedback

- [ ] **POLISH-01**: Haptic feedback triggers on swipe actions
- [ ] **POLISH-02**: Haptic feedback triggers on button taps
- [ ] **POLISH-03**: Swipe threshold configured for responsive feel (40-50% card width)
- [ ] **POLISH-04**: UI adapts smoothly to orientation changes without breaking layout

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Advanced Customization

- **CUSTOM-01**: User can adjust swipe threshold sensitivity in settings
- **CUSTOM-02**: User can customize spring animation feel (response/damping)

### Enhanced Export

- **ENHANCE-01**: User can reorder clips in export selection screen
- **ENHANCE-02**: User can preview stitched video before exporting
- **ENHANCE-03**: User can trim individual clips before export

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Multi-level undo (>1 action) | Adds state management complexity, single-level undo provides sufficient safety net |
| Delete confirmation dialogs | Slows workflow, undo provides safety, visual feedback during swipe is sufficient |
| Swipe up/down for additional actions | Adds cognitive load, left/right + undo covers 99% of use cases |
| In-app video trimming | Scope creep, AI detection should produce good rally boundaries |
| Social sharing to platforms | Privacy concerns (volleyball footage often includes minors), workflow mismatch |
| Real-time rally detection | Focus is on post-processing review, separate feature domain |
| Cloud sync of liked clips | Local-only app architecture, export to camera roll sufficient |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| (populated during roadmap creation) | | |

**Coverage:**
- v1 requirements: 40 total
- Mapped to phases: (pending roadmap)
- Unmapped: (pending roadmap)

---
*Requirements defined: 2026-01-24*
*Last updated: 2026-01-24 after initial definition*
