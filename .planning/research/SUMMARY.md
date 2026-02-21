# Project Research Summary

**Project:** SwiftUI Card Stack Video Viewer (Tinder-style Rally Review)
**Domain:** Short-form video card stack interface
**Researched:** 2026-01-24
**Confidence:** HIGH

## Executive Summary

BumpSetCut needs a Tinder-style swipeable card stack for reviewing rally clips with full-screen video playback. Research shows this is a well-established pattern combining horizontal swipe gestures (like/delete) with vertical navigation (next/previous rally) and autoplay video. The recommended approach uses native SwiftUI DragGesture with existing AVPlayer infrastructure (RallyVideoPlayer, RallyPlayerCache) rather than third-party card libraries that add dependencies and break on iOS updates.

The critical success factors are: (1) proper AVPlayer lifecycle management to prevent memory leaks, (2) gesture priority hierarchy to avoid swipe/tap conflicts, (3) stable zIndex architecture to prevent animation glitches, and (4) orientation-aware video sizing without recreating players. BumpSetCut already has proven implementations of player caching, thumbnail preloading, and async video handling that can be reused—the main architectural work is the gesture system and state-driven card removal.

Key risks include AVPlayer memory leaks from NotificationCenter observers (iOS 17 regression), gesture conflicts between card swipes and video taps, and zIndex animation bugs during card removal. All three must be addressed in Phase 1 (Core Card Stack) as they cannot be retrofitted easily. Research confidence is HIGH because the codebase already implements most required patterns (RallyPlayerView, RallyPlayerCache, VideoExporter) and recommendations are verified against iOS 18 APIs and working code.

## Key Findings

### Recommended Stack

**Core technologies (all iOS 18.0+ native, zero dependencies):**
- **SwiftUI DragGesture:** Swipe gesture recognition with velocity detection—already proven in RallyPlayerView.swift, iOS 18 enhanced gesture handling
- **AVFoundation/AVPlayer:** Video playback with `replaceCurrentItem(with:)` for player reuse—already integrated, memory-efficient pattern via RallyPlayerCache
- **matchedGeometryEffect:** Page-peel card transition animations—native SwiftUI modifier for hero-style transitions, standard approach in 2025
- **PHPhotoLibrary:** Export saved rallies to camera roll—already in VideoExporter.swift, requires Info.plist permission

**Supporting techniques:**
- Spring animations (`.spring(response: 0.4, dampingFraction: 0.8)`)—already used in RallyPlayerView, iOS 18 enhanced physics
- zIndex layering—already implemented in `zIndexForPosition()`, critical for proper stacking
- `.scaleEffect()` and `.offset()` for card peek effect—already implemented in `scaleForPosition()`

**What NOT to use:**
- Third-party card stack libraries (breaks on OS updates, hides complexity)—use native DragGesture + ZStack
- Multiple AVPlayer instances per card (memory leaks)—use single AVPlayer with `replaceCurrentItem(with:)`
- VideoPlayer (SwiftUI native)—limited customization, use AVPlayer in UIViewRepresentable (already done)

### Expected Features

**Must have (table stakes):**
- Swipe left/right gestures (core Tinder/Reels metaphor)—users assume this exists
- Tap action buttons as alternative (accessibility + one-handed use)—Tinder standard
- Visual feedback during drag (card follows finger, rotation, action hints)—prevents "broken" feel
- Spring physics on release (realistic bounce/settle)—non-negotiable for polish
- Immediate video autoplay with seamless loop (short-form video expectation)—no play button needed
- Smooth orientation transitions (portrait/landscape without breaking playback)—iOS user expectation
- Single-level undo (safety net for accidental swipes)—Tinder/Bumble standard

**Should have (competitive advantage):**
- Page-peel animation (more satisfying than slide)—differentiator, reinforces card metaphor
- Batch export with visual selection (checkbox UI)—volleyball coaches need compilation videos
- Select all/deselect all toggle (quick curation)—QoL for 20+ rally clips
- Explicit like/delete actions (most clones only have "like")—reduces post-review cleanup
- Empty state with parent video delete option (contextual cleanup)—saves navigation
- Haptic feedback on actions (iOS 26 standard)—perceived quality boost

**Defer (v2+):**
- Multi-level undo (>1 action)—adds complexity, rarely used beyond 1 level
- Delete confirmation dialogs (kills swipe flow)—undo provides safety net
- In-app video trimming (scope creep)—AI detection should produce good boundaries
- Swipe up/down for other actions (cognitive load)—left/right + undo covers 99%

**Anti-features (commonly requested, problematic):**
- Multi-level undo—confuses state management, Tinder doesn't have it
- Delete confirmation dialogs—slows workflow, visual feedback during swipe is enough
- Reorder clips in export—complex drag-drop UI, most users don't care
- Share individual clips to social—privacy/workflow mismatch (volleyball footage often includes minors)

### Architecture Approach

BumpSetCut follows feature-based organization with proven patterns already in place. The card stack viewer fits as a new feature module (`Features/CardStackReview/`) leveraging existing services (MediaStore, VideoExporter, RallyPlayerCache). Architecture uses state-driven card removal via @Observable ViewModel—swipe actions modify card array, triggering SwiftUI's automatic re-render and animations.

**Major components:**
1. **CardStackContainer** — ZStack with ForEach rendering cards in reverse order, applies depth offsets (`.stacked()` modifier)
2. **SwipeableCard** — Individual card owning its own drag gesture state, contains video player and overlays
3. **GestureHandler** — Pure-function calculator for swipe direction/distance, no state, easily testable
4. **CardStackReviewViewModel** — @Observable state manager with card array, action history for undo, swipe threshold config
5. **RallyVideoPlayer (reuse)** — Existing AVPlayer wrapper with RallyPlayerCache for memory-efficient playback
6. **VideoExporter (reuse)** — Existing export service for batch/stitched export workflow

**Key patterns:**
- **State-driven card removal:** Cards are array in ViewModel, swipe modifies array, SwiftUI handles animations automatically
- **Gesture-based direction detection:** DragGesture calculates angle/distance, maps to discrete directions with configurable threshold
- **Cached video player per card:** RallyPlayerCache manages AVPlayer instances (top 3-4 cards), prevents memory leaks
- **Orientation-aware sizing:** Calculate `isPortrait` once per update, reuse value (don't recalculate in view body)

**Data flow:**
```
User Swipe → GestureCalculator → SwipeableCard callback → ViewModel updates card array →
ZStack re-renders → RallyPlayerCache releases player for removed card
```

### Critical Pitfalls

1. **AVPlayer memory leaks from NotificationCenter observers** — Observers create strong reference cycles, memory accumulates rapidly when swiping through cards. **Prevent:** Always use `[weak player]` in observers, store observer tokens, remove explicitly before cleanup, call `player.pause()` and `player.replaceCurrentItem(with: nil)` before deallocation. **Phase 1 issue—foundational, cannot retrofit.**

2. **Gesture conflicts between card swipe and video player tap** — DragGesture prevents tap gestures from working, or both fire simultaneously creating "dancing" UI. iOS 18 behavior differs from iOS 17. **Prevent:** Use `.highPriorityGesture()` for dominant gesture, disable video interactions during drag with `.disabled(isDragging)`, test on multiple iOS versions. **Phase 1 issue—affects gesture architecture.**

3. **ZIndex animation bugs with dynamic card stacks** — Cards "jump" positions or fly in from wrong directions when added/removed because SwiftUI recalculates zIndex during state changes. zIndex is not animatable. **Prevent:** Use stable explicit zIndex tied to stable identifiers (not array indices), calculate from stack position relative to current card. **Phase 1 issue—cannot fix without rewriting animation system.**

4. **Orientation change video player crashes** — App crashes/freezes when rotating device during video playback, or shows black screen after rotation. **Prevent:** Calculate orientation once per view update and cache, don't recreate players on rotation (reuse and adjust frame only), pause seeking during orientation transitions. **Phase 2 issue—affects player lifecycle design.**

5. **CMTime seeking race conditions with rally segments** — Seeking to rally start times fails intermittently, multiple rapid swipes cause seeks to execute out of order. **Prevent:** Use `seek(to:toleranceBefore:toleranceAfter:)` with reasonable tolerance, call with completion handler, throttle rapid seeks, use base URL only (no fragment identifiers). **Phase 2 issue—affects perceived responsiveness.**

6. **Background/foreground state persistence failure** — User backgrounds app, returns 10 minutes later, app shows wrong rally or crashes. Playback state and undo stack lost. **Prevent:** Persist critical state to UserDefaults/file on backgrounding, subscribe to app lifecycle notifications, don't auto-play on foreground. **Phase 3 issue—requires testing scenarios not in normal dev flow.**

7. **Thumbnail generation blocking main thread** — UI freezes 1-3 seconds when swiping to new card while thumbnail extracts. **Prevent:** Always use `generateCGImageAsynchronously()` on background queue, set `maximumSize` to reasonable dimensions (720p), preload during idle time, show placeholder immediately. **Phase 4 issue—only critical for peek preview feature.**

8. **Audio session conflicts with multiple AVPlayers** — Both videos play audio simultaneously during swipe, or audio stops working after 3-4 videos. **Prevent:** Configure audio session once at app/scene level (not per-player), pause previous player before playing next, use single shared audio session for all players. **Phase 2 issue—must architect correctly with first AVPlayer.**

## Implications for Roadmap

Based on research, recommended 5-phase structure aligned with dependency chains and risk mitigation:

### Phase 1: Core Card Stack (No Video)
**Rationale:** Validate gesture system and animation architecture before adding video complexity. Critical pitfalls (memory leaks, gesture conflicts, zIndex bugs) must be addressed in Phase 1 as they cannot be retrofitted easily.

**Delivers:**
- Swipeable card stack with placeholder content (colored rectangles)
- DragGesture with direction detection and threshold
- Spring physics animations on release/snap-back
- Depth stacking effect (scale + offset)
- Stable zIndex architecture using identifiers (not indices)
- Tap action buttons (like/delete) as gesture alternative

**Addresses (from FEATURES.md):**
- Swipe left/right gestures (P1)
- Visual feedback during drag (P1)
- Spring physics on release (P1)
- Tap action buttons (P1)

**Avoids (from PITFALLS.md):**
- Gesture conflicts (#2)—architect `.highPriorityGesture()` from start
- zIndex animation bugs (#3)—use stable identifiers, test deletion animations
- Technical debt—never use `.gesture()` without priority, never use indices for zIndex

**Research flag:** NO ADDITIONAL RESEARCH NEEDED—well-documented pattern, existing codebase has proven examples (RallyPlayerView gesture system)

---

### Phase 2: Video Playback Integration
**Rationale:** Build on validated gesture/state foundation, integrate existing video infrastructure (RallyVideoPlayer, RallyPlayerCache). Must address orientation and audio session issues during initial integration (cannot bolt on later).

**Delivers:**
- RallyVideoPlayer in SwipeableCard
- RallyPlayerCache integration (limit 4 players max)
- Autoplay on card reveal, pause on swipe away
- Seamless video looping (AVPlayerLooper)
- Orientation-aware video sizing (portrait .fit, landscape .fill)
- Single shared audio session configuration

**Uses (from STACK.md):**
- AVFoundation/AVPlayer with `replaceCurrentItem(with:)`
- RallyPlayerCache (existing)—reuse pattern proven in RallyPlayerView
- Orientation calculation (existing)—`isPortrait` computed property

**Implements (from ARCHITECTURE.md):**
- Cached video player per card pattern
- Player lifecycle management (cleanup on swipe)
- Orientation-aware sizing without player recreation

**Avoids (from PITFALLS.md):**
- AVPlayer memory leaks (#1)—explicit cleanup with `[weak player]`, remove observers, nil out before dealloc
- Orientation crashes (#4)—cache orientation calc, preserve player instance across rotation
- CMTime seeking race conditions (#5)—use tolerance, completion handlers, throttle seeks
- Audio session conflicts (#8)—single shared session configured once at app level

**Research flag:** NO ADDITIONAL RESEARCH NEEDED—existing codebase provides working patterns (RallyPlayerCache.swift, RallyVideoPlayer.swift), iOS 18 AVFoundation APIs well-documented

---

### Phase 3: State Management & Persistence
**Rationale:** Core functionality works, now make it production-ready with undo, persistence, and backgrounding support. Deferred to Phase 3 because it requires testing scenarios (backgrounding, state restoration) not covered by normal development flow.

**Delivers:**
- CardStackReviewViewModel with @Observable state
- ActionHistory for single-level undo
- Reverse animation for card restoration
- State persistence to UserDefaults (current index, saved/removed rallies)
- App lifecycle handling (background/foreground notifications)
- MediaStore integration for metadata updates (isLiked, isDeleted flags)

**Addresses (from FEATURES.md):**
- Single-level undo (P1)—safety net for accidental swipes
- Last card awareness (P1)—show indicator when stack ends

**Implements (from ARCHITECTURE.md):**
- State-driven card removal pattern
- ActionHistoryManager for undo stack
- MediaStore integration via .libraryContentChanged notification

**Avoids (from PITFALLS.md):**
- Background/foreground state persistence failure (#6)—persist on background, restore on foreground, clear undo stack explicitly
- Technical debt—don't store AVPlayer in @State (iOS 17 regression), use explicit lifecycle management

**Research flag:** NO ADDITIONAL RESEARCH NEEDED—standard @Observable + Codable persistence, UserDefaults pattern, NotificationCenter lifecycle observers

---

### Phase 4: Batch Export & Selection
**Rationale:** End-to-end feature completion using existing VideoExporter service. Depends on working state management (Phase 3) to track saved rallies.

**Delivers:**
- Batch export screen with checkbox selection
- Individual or stitched export modes
- Select all/deselect all toggle
- Export progress with cancel option
- Share sheet integration (existing PHPhotoLibrary)
- Empty state with parent video delete option

**Addresses (from FEATURES.md):**
- Batch export with visual selection (P1)—differentiator for volleyball coaches
- Select all/deselect all (P1)—QoL for 20+ clips
- Empty state cleanup (P1)—contextual action

**Implements (from ARCHITECTURE.md):**
- ExportCoordinator pattern
- Reuse VideoExporter.exportStitchedRalliesToPhotoLibrary() (existing)
- MediaStore cleanup methods for parent video deletion

**Avoids (from PITFALLS.md):**
- Anti-pattern: Reimplementing export logic (#4)—inject existing VideoExporter service

**Research flag:** NO ADDITIONAL RESEARCH NEEDED—existing VideoExporter.swift handles stitching, orientation, photo library access. Leverage proven implementation.

---

### Phase 5: Polish & Advanced Features
**Rationale:** All core functionality complete and stable. Add nice-to-haves based on user feedback and performance validation. Deferred because they're non-essential for launch.

**Delivers:**
- Page-peel animation (if users request "more satisfying" feel)
- Haptic feedback on swipe actions (UIImpactFeedbackGenerator)
- Swipe threshold customization in settings
- Thumbnail peek preview for next card
- Performance optimizations (Instruments profiling)

**Addresses (from FEATURES.md):**
- Page-peel animation (P2)—differentiator but HIGH complexity
- Haptic feedback (P2)—iOS 26 standard, easy win for perceived quality
- Swipe threshold customization (P3)—power user feature

**Uses (from STACK.md):**
- matchedGeometryEffect for page-peel
- RallyThumbnailCache (existing) for peek preview
- Xcode Instruments 26 SwiftUI analyzer for performance

**Avoids (from PITFALLS.md):**
- Thumbnail blocking main thread (#7)—always use `generateCGImageAsynchronously()` on background queue
- Performance traps—limit visible card stack to 4 cards max, preload thumbnails during idle time

**Research flag:** NEEDS RESEARCH FOR PAGE-PEEL—complex custom animation beyond standard SwiftUI, may need research-phase for implementation techniques and performance optimization

---

### Phase Ordering Rationale

**Dependency-driven sequencing:**
- Phase 1 before Phase 2: Gesture system must be solid before adding video (video player tap conflicts with swipe)
- Phase 2 before Phase 3: Player lifecycle must work before state persistence (can't persist invalid player state)
- Phase 3 before Phase 4: State management must track saved rallies before batch export can collect them
- Phase 5 last: Polish depends on stable foundation, informed by user feedback from Phases 1-4

**Risk mitigation sequencing:**
- Critical pitfalls (#1, #2, #3) addressed in Phase 1 because they're architectural and cannot be retrofitted
- Moderate pitfalls (#4, #5, #8) addressed in Phase 2 during initial video integration
- Minor pitfalls (#6, #7) deferred to later phases (backgrounding, thumbnails) where they're most relevant

**Architectural alignment:**
- Phases match build order recommendations from ARCHITECTURE.md (Core Card Stack → State Management → Video Integration → Export → Polish)
- Each phase delivers working increment that can be tested independently
- Reuses existing services incrementally (RallyPlayerCache in Phase 2, VideoExporter in Phase 4)

### Research Flags

**Needs deeper research during planning:**
- **Phase 5 (page-peel animation):** Complex custom animation, GPU-intensive, needs performance optimization research. Consider `/gsd:research-phase` when user feedback confirms this is valuable.

**Standard patterns (skip research-phase):**
- **Phase 1 (Core Card Stack):** Well-documented DragGesture pattern, existing codebase has proven examples
- **Phase 2 (Video Integration):** Existing codebase provides working patterns (RallyPlayerCache, RallyVideoPlayer)
- **Phase 3 (State Management):** Standard @Observable + Codable persistence, no novel patterns
- **Phase 4 (Batch Export):** Reuses existing VideoExporter, straightforward UI work

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All recommendations verified against iOS 18 APIs and existing working code (RallyPlayerView, RallyPlayerCache). Zero dependencies, native SwiftUI patterns. |
| Features | MEDIUM | Table stakes confirmed via iOS HIG and competitor analysis (short-form video apps, Tinder). Specific thresholds (40-50% swipe distance) based on library defaults, may need tuning. |
| Architecture | HIGH | Directly analyzed existing BumpSetCut codebase—feature-based modules, @Observable ViewModels, MediaStore patterns all proven. Recommended structure fits naturally. |
| Pitfalls | HIGH | Critical pitfalls (#1-#3) verified via Apple Developer Forums, iOS 17 regression docs, existing codebase audit. Phase mapping based on component dependencies. |

**Overall confidence:** HIGH

Research is strongly grounded in existing codebase analysis (RallyPlayerView.swift, RallyPlayerCache.swift, VideoExporter.swift) combined with iOS 18 official documentation. Most recommended patterns are already implemented elsewhere in BumpSetCut and just need to be composed into new feature module.

### Gaps to Address

**During planning:**
- **Swipe threshold tuning:** Research suggests 40-50% of card width, but this needs user testing to feel responsive without accidental triggers. Plan for iteration in Phase 1 testing.
- **Page-peel animation performance:** HIGH complexity feature with GPU concerns. Defer to Phase 5 and consider skipping if simpler slide animation satisfies users (validate demand first).
- **Exact spring animation parameters:** Research shows `response: 0.4, dampingFraction: 0.8` works in RallyPlayerView, but may need adjustment for card stack (different mass/velocity). Plan for tweaking in Phase 1.

**During implementation:**
- **iOS 17 vs iOS 18 gesture behavior:** Research flags differences in gesture priority handling. Must test on both OS versions during Phase 1 to ensure consistent behavior.
- **Device performance for page-peel:** Research warns 60fps target may drop to 30fps on older devices. If implementing in Phase 5, set minimum device requirement (iPhone 12+) or provide fallback slide animation.
- **Thumbnail extraction performance:** Research shows simulator is 10x faster than device. Always profile on physical device during Phase 4 (peek preview) to catch main thread blocking.

## Sources

### Primary (HIGH confidence)
- **Existing BumpSetCut codebase:** Direct analysis of RallyPlayerView.swift (gesture system, zIndex, orientation), RallyPlayerCache.swift (player lifecycle, cleanup), RallyVideoPlayer.swift (AVPlayer wrapper), VideoExporter.swift (PHPhotoLibrary export), UnifiedRallyCard.swift (async thumbnail loading)
- **Apple Developer Documentation (iOS 18):** SwiftUI DragGesture API, AVFoundation AVPlayer lifecycle, Photos framework PHPhotoLibrary, matchedGeometryEffect animation modifier
- **iOS 26 Human Interface Guidelines:** Haptic feedback patterns, gesture interaction design, orientation handling best practices

### Secondary (MEDIUM confidence)
- **Apple Developer Forums (2025):** iOS 17 @State AVPlayer memory leak regression (thread 743014), iOS 18 DragGesture behavior changes (thread 774305)
- **WWDC 2025 Sessions:** Session 306 "Optimize SwiftUI performance with Instruments" (Instruments 26 view body analyzer, 60fps targets)
- **Community SwiftUI libraries:** GitHub dadalar/SwiftUI-CardStackView, tobi404/SwipeCardsKit (architecture patterns, state management approaches)
- **Medium articles (Nov 2025):** matchedGeometryEffect deep-dive (SwiftUI Lab hero animations), AVPlayer lifecycle in SwiftUI (cleanup patterns)

### Tertiary (LOW confidence, needs validation)
- **Swipe threshold percentages (40-50%):** Based on community library defaults, not empirical user research—plan for tuning during Phase 1 testing
- **Card rotation angle recommendations (5-15°):** Design heuristic from community articles, not backed by UX research—validate feel during implementation
- **Preloading strategy (next 1-2 videos):** Performance assumption from research, needs device testing to confirm memory/battery impact

---
*Research completed: 2026-01-24*
*Ready for roadmap: yes*
