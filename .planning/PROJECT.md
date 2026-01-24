# BumpSetCut - Rally Viewer Refinement

## What This Is

An iOS app that automatically detects volleyball rallies in recorded footage and extracts them into reviewable clips. This milestone focuses on refining the rally viewing experience with an intuitive swipe-based interface and polished export workflow.

## Core Value

Users can quickly review AI-detected rally clips with simple swipe gestures to keep the best moments and export them seamlessly.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Video upload from photo library and camera recording — existing
- ✓ AI-powered rally detection using YOLO CoreML model — existing
- ✓ File-based storage with JSON manifests (MediaStore) — existing
- ✓ Basic rally playback interface — existing
- ✓ Video export to camera roll — existing
- ✓ Folder organization for videos — existing
- ✓ Processing metadata tracking — existing

### Active

<!-- Current scope. Building toward these. -->

- [ ] Tinder-style card stack interface for rally viewing
- [ ] Page-peel animation when swiping between clips
- [ ] Swipe right or tap heart button to like (save) clip
- [ ] Swipe left or tap trash button to delete clip
- [ ] Single-level undo with reverse peel animation
- [ ] Auto-play clips immediately when revealed
- [ ] Portrait mode: video fits screen without stretching, buttons at bottom
- [ ] Landscape mode: video fills screen, buttons repositioned to bottom
- [ ] Export screen with checkbox selection of liked clips
- [ ] Select all / deselect all toggle for export selection
- [ ] Export individual clips or stitched video to camera roll
- [ ] Export confirmation dialog with progress indicator
- [ ] Empty state when no clips liked with option to delete parent video or return home

### Out of Scope

- Clip reordering in export flow — deferred to future version
- Real-time rally detection during camera recording — focus is on post-processing
- Cloud sync or sharing features — local-only app
- Multiple undo levels — single undo is sufficient for this interface
- Delete confirmation dialogs — undo provides safety net

## Context

**Existing Architecture:**
- SwiftUI iOS app with feature-based modular architecture
- MVVM pattern with @Observable view models
- File-based storage (no database)
- AVFoundation for video processing and playback
- Current rally playback uses TikTok-style vertical swipe (see RallyPlaybackView)

**User Experience Goals:**
- Fast, fluid gestures for quick review of many clips
- Clear visual feedback for actions (animations, button states)
- No cognitive load - swipe direction matches action intent
- Forgiving interface with undo for accidental actions

**Technical Considerations:**
- Must handle orientation changes smoothly without breaking playback
- Page-peel animation needs to be performant (60fps)
- Export can be slow for stitched videos - progress UI critical
- Liked/deleted state needs to persist if user leaves and returns

## Constraints

- **Platform**: iOS 18.0+ only, SwiftUI-based
- **Video Framework**: AVFoundation for playback (existing dependency)
- **Storage**: File-based with JSON metadata (MediaStore pattern)
- **Animation**: Native SwiftUI animations preferred, but custom if needed for peel effect
- **Export Destination**: Camera roll via PHPhotoLibrary (existing permission)
- **Performance**: Page-peel animation must be smooth (60fps target)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Single-level undo only | Keeps interface simple, users rarely need deeper history | — Pending |
| No delete confirmation | Undo provides safety, confirmation slows workflow | — Pending |
| Auto-play on reveal | Immediate feedback, users can swipe past quickly if needed | — Pending |
| Export greyed out when no selection | Clear affordance, prevents null exports | — Pending |

---
*Last updated: 2026-01-24 after initialization*
