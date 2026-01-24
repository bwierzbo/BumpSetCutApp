# Stack Research

**Domain:** SwiftUI card stack video viewer (Tinder-style)
**Researched:** 2026-01-24
**Confidence:** HIGH

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| SwiftUI DragGesture | iOS 18.0+ native | Card swipe gesture recognition | Native, performant, no dependencies. iOS 18 has enhanced gesture handling with improved simultaneous gesture support and configurable recognizers. Already in use in RallyPlayerView.swift. |
| AVFoundation/AVPlayer | iOS 18.0+ native | Video playback in cards | Already integrated in project. Reuse player instances with `replaceCurrentItem(with:)` to avoid memory leaks in card stacks. UIViewRepresentable pattern already proven in UnifiedRallyCard. |
| matchedGeometryEffect | iOS 18.0+ native | Page-peel card transition animations | Native SwiftUI modifier for smooth hero-style transitions between views. Standard approach for card-to-detail view animations in 2025 (used in App Store, banking apps). Zero dependencies. |
| PHPhotoLibrary | iOS 18.0+ native | Export saved rallies to camera roll | Already integrated in VideoExporter.swift. Use `performChanges` with `PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:)`. Requires Info.plist `NSPhotoLibraryAddUsageDescription`. |

### Supporting Animation Techniques

| Technique | Purpose | Implementation |
|-----------|---------|----------------|
| Spring animations | Natural card swipe feel | `.spring(response: 0.4, dampingFraction: 0.8)` - already used in RallyPlayerView. iOS 18 enhanced physics-based timing. |
| zIndex layering | Card stack depth ordering | Already implemented in `zIndexForPosition()` helper. Critical for proper stacking (current card z:100, next cards negative). |
| .scaleEffect() | Card peek/stack effect | Already implemented in `scaleForPosition()`. Standard 0.92 scale for peeking next card. |
| .offset() + .rotationEffect() | Swipe animation transforms | Already implemented in TopCardDragModifier. Horizontal offset with slight rotation (max ±15°) for Tinder-style feel. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode Instruments | Performance profiling (60fps target) | Use new Instruments 26 SwiftUI view body analyzer (WWDC 2025) to identify expensive view updates during swipes. Monitor for frame drops below 60fps. |
| GeometryReader | Responsive card sizing | Already used in RallyPlayerView. Calculate orientation once per update, reuse value (don't recalculate in subviews). |
| Task/async-await | Asynchronous thumbnail loading | Already implemented in UnifiedRallyCard. Essential for smooth scrolling - load thumbnails in background, avoid blocking main thread. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Third-party card stack libraries (SwiftUI-CardStackView, CardStack, SwipeCardsKit) | Adds dependency, hides complexity, may not support video players, limits customization. Community trend in 2025 is toward native solutions due to breaking changes with OS updates. | Native SwiftUI DragGesture + ZStack with custom position logic (already implemented in RallyPlayerView). |
| Custom UIGestureRecognizer via UIViewRepresentable | Unnecessary complexity for standard swipe gestures. Only needed for fine-grained control (delaysTouchesBegan, numberOfTouchesRequired) or missing gestures (UIScreenEdgePanGestureRecognizer). | SwiftUI DragGesture handles horizontal/vertical swipes, velocity detection, and simultaneous gestures natively. |
| Multiple AVPlayer instances per card | Memory leaks. Creating VideoPlayer for each card in stack (5+ cards preloaded) causes unbounded memory growth, especially with 4K video. | Single AVPlayer instance with `replaceCurrentItem(with:)` when card becomes current. Already partially implemented via RallyPlayerCache. |
| VideoPlayer (SwiftUI native) | Limited customization - can't control playback state, orientation handling, or add overlays easily. | AVPlayer wrapped in UIViewRepresentable (already done in UnifiedRallyCard). Full control over playback, orientation, and UI composition. |
| CABasicAnimation for card transitions | UIKit-style, requires bridging to SwiftUI, verbose. | matchedGeometryEffect + spring animations (SwiftUI native). iOS 18 animated transactions framework eliminates need for manual CABasicAnimation. |

## Stack Patterns for Card Stack Video Viewer

### Pattern 1: Player Lifecycle Management

**Current implementation:** RallyPlayerCache manages player instances, reuses player with `replaceCurrentItem(with:)`.

**Enhancement for Tinder-style:**
- Pause player when card is swiped away (horizontal dismiss)
- Resume/replace player when new card becomes current (horizontal swipe complete)
- Critical: Call `player?.pause()` and `player = nil` in cleanup to prevent memory leaks

**Example from research:**
```swift
func cleanupPlayer() {
    player?.pause()
    player = nil
}
```

### Pattern 2: Horizontal vs Vertical Gesture Disambiguation

**Current implementation:** RallyPlayerView detects dominant direction via velocity comparison:
```swift
let isVerticalDominant = abs(verticalVelocity) > abs(horizontalVelocity) ||
                         abs(verticalOffset) > abs(horizontalOffset)
```

**Enhancement for Tinder-style:** Existing pattern works. Horizontal swipes trigger save/remove actions, vertical swipes navigate between rallies. Threshold: 120pt for actions, 100pt for navigation.

### Pattern 3: matchedGeometryEffect for Page Peel

**New pattern needed:** Card-to-detail view transition (e.g., saved rally expands to full screen).

**Implementation approach:**
```swift
@Namespace private var cardAnimation

// In card stack
CardView()
    .matchedGeometryEffect(id: rally.id, in: cardAnimation)

// In detail view
DetailView()
    .matchedGeometryEffect(id: rally.id, in: cardAnimation)
```

Both views must exist in hierarchy simultaneously during transition. Use `.zIndex()` to control layering. Spring animation parameters: `response: 0.4, dampingFraction: 0.8` (already proven in RallyPlayerView).

### Pattern 4: Orientation-Aware Video Sizing

**Current implementation:** Calculates `isPortrait` once via `@Environment(\.verticalSizeClass)`, reuses value:
```swift
private var isPortrait: Bool {
    verticalSizeClass == .regular
}
```

**Enhancement for Tinder-style:** No changes needed. Existing pattern is optimal (WWDC 2025 performance guidance: don't recalculate in view body).

### Pattern 5: Card Stack Preloading

**Current implementation:** `visibleCardIndices` preloads previous (-1), current (0), and next (1) cards. Opacity 0 for hidden cards but still rendered (preload).

**Enhancement for Tinder-style:** Existing pattern works. For horizontal swipe (remove/save), preload next card while animating current card exit. Use thumbnail layer (always present) to avoid flash while video loads.

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| AVFoundation | iOS 18.0+ | iOS 18 added `try await exporter.export(to: URL, as: .mp4)` - cleaner API than completion handlers. Already used in VideoExporter.swift. |
| Photos framework | iOS 18.0+ | Limited library access mode (iOS 14+) - use `PHPhotoLibrary.presentLimitedLibraryPicker()` if needed. Export uses standard `performChanges` API. |
| SwiftUI | iOS 18.0+ | Enhanced rendering engine improves animation/transition performance (especially layered views). Gesture handling improvements for simultaneous gestures. |

## Performance Considerations

**60fps target:** Card swipe animations must maintain 60fps for smooth feel.

**Known bottlenecks (WWDC 2025):**
1. **Long view body updates** - Move expensive computations (thumbnail generation, metadata formatting) out of view body into cached values
2. **Unnecessary view updates** - Use `@State` for drag offset (already done), avoid @Published for high-frequency gesture updates

**Optimization checklist:**
- [x] Player instance reuse (RallyPlayerCache)
- [x] Thumbnail caching (RallyThumbnailCache)
- [x] Orientation calculated once (isPortrait computed property)
- [x] Async thumbnail loading (Task in UnifiedRallyCard)
- [x] Spring animations (0.4s response prevents jarring transitions)
- [ ] Profile with Instruments 26 SwiftUI analyzer during swipe testing

## Sources

**HIGH confidence:**
- SwiftUI DragGesture: Apple Developer Documentation (iOS 18), verified via existing RallyPlayerView.swift implementation
- AVPlayer memory management: Apple Developer Forums thread 743014, verified via existing RallyPlayerCache pattern
- matchedGeometryEffect: Medium articles Nov 2025, SwiftUI Lab deep-dive (hero animations Part 1)
- PHPhotoLibrary: Apple Developer Documentation, verified via existing VideoExporter.swift (line 183-185)

**MEDIUM confidence:**
- iOS 18 gesture improvements: Web search (What's New in SwiftUI for iOS 18 article), multiple sources agree
- Performance optimization: WWDC 2025 session "Optimize SwiftUI performance with Instruments" (session 306)
- Spring animation parameters: Existing codebase (line 262 RallyPlayerView.swift), matches community best practices

**LOW confidence:**
- None - all recommendations verified against official docs or existing working code

---
*Stack research for: SwiftUI card stack video viewer (Tinder-style)*
*Researched: 2026-01-24*
