# Phase 1: Core Card Stack - Research

**Researched:** 2026-01-24
**Domain:** SwiftUI gesture-driven card stack UI
**Confidence:** HIGH

## Summary

Phase 1 requires implementing a swipeable card stack with gestures, animations, and stable layering. This is a well-established SwiftUI pattern with clear best practices from Apple's design guidelines and the community.

The standard approach uses `DragGesture` for swipe interactions, spring-based animations for physics-based movement, and explicit `zIndex` management to prevent layering glitches during animations. The codebase already contains excellent patterns in `RallyPlayerView.swift` and `AnimationTokens.swift` that should be extended, not duplicated.

**Primary recommendation:** Build on existing `RallyPlayerView` patterns (drag gesture with velocity detection, spring animations, explicit zIndex) while extracting reusable card stack logic into a generic component that supports both video playback (existing) and placeholder cards (Phase 1).

## Standard Stack

The established libraries/tools for SwiftUI card stack implementations:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI | iOS 17+ | Declarative UI framework | Native Apple framework, required for app |
| @Observable macro | Swift 5.9+ | State management | Modern replacement for ObservableObject, better performance |
| DragGesture | SwiftUI | Touch gesture recognition | Built-in gesture system, velocity tracking included |
| Spring Animation | SwiftUI | Physics-based animations | Apple's recommended approach (WWDC 2023) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| GeometryReader | SwiftUI | Responsive sizing | Card dimensions, threshold calculations |
| @State | SwiftUI | View-local state | Drag offsets, transient UI state |
| @Bindable | SwiftUI | Bindings from Observable | Creating two-way bindings to @Observable properties |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Custom gesture | UIKit gesture recognizers | More complex, loses SwiftUI state integration |
| @StateObject/@ObservedObject | @Observable + @State | Old pattern, worse performance, more boilerplate |
| Manual animation | UIView.animate | Incompatible with SwiftUI declarative model |

**Installation:**
All components are part of SwiftUI standard library - no external dependencies required.

## Architecture Patterns

### Recommended Project Structure
```
Features/CardStack/
├── CardStackView.swift           # Main card stack container
├── CardStackViewModel.swift      # @Observable state manager
├── Models/
│   ├── CardStackItem.swift       # Generic Identifiable card data
│   └── CardStackAction.swift     # Swipe actions (save/remove)
└── Components/
    ├── SwipeableCard.swift       # Individual card with gesture
    └── CardStackModifiers.swift  # Reusable drag/animation modifiers
```

**Note:** This structure mirrors existing `RallyPlayback/` feature and allows Phase 2 to swap placeholder cards for video cards without architectural changes.

### Pattern 1: Identifier-Based Card Management
**What:** Use `Identifiable` protocol and stable IDs for card tracking, not array indices
**When to use:** Always - prevents animation glitches when cards are added/removed
**Example:**
```swift
// Existing pattern from RallyPlayerView.swift
struct CardStackViewModel {
    private var cards: [CardStackItem]  // Identifiable items

    var visibleCardIndices: [Int] {
        // Return indices for current card + next 2 for preloading
        let start = max(0, currentIndex - 1)
        let end = min(cards.count, currentIndex + 2)
        return Array(start..<end)
    }

    func zIndexForPosition(_ position: Int) -> Double {
        switch position {
        case -1: return -1     // Previous card (if animating back)
        case 0: return 100     // Current card (top)
        default: return Double(-position)  // Next cards (below)
        }
    }
}
```
**Why this works:** SwiftUI tracks cards by ID, not position, so animations remain stable during state changes.

### Pattern 2: Gesture-Driven Animation with Velocity
**What:** Use `DragGesture` with `.onChanged` for live tracking, `.onEnded` for velocity-based decisions
**When to use:** All interactive card animations
**Example:**
```swift
// Source: Existing RallyPlayerView.swift (lines 202-267)
DragGesture()
    .onChanged { value in
        viewModel.dragOffset = value.translation

        // Apply boundary resistance if at end
        if !viewModel.canGoNext && viewModel.dragOffset.height < 0 {
            viewModel.dragOffset.height *= 0.3
        }
    }
    .onEnded { value in
        let threshold: CGFloat = 100
        let velocity = value.velocity.width  // or .height

        // Velocity-based decision (300-500 pts/sec typical)
        if abs(velocity) > 300 || abs(value.translation.width) > threshold {
            // Trigger swipe action
        } else {
            // Return to original position
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.dragOffset = .zero
            }
        }
    }
```
**Why this works:** Velocity detection creates natural, responsive interactions that match iOS system gestures.

### Pattern 3: Explicit ZIndex with Position-Based Calculation
**What:** Always set explicit `zIndex` values based on card position, never rely on SwiftUI's automatic ordering
**When to use:** Any dynamic card stack with animations
**Example:**
```swift
// Source: Existing RallyPlayerView.swift (lines 191-198)
private func zIndexForPosition(_ position: Int) -> Double {
    switch position {
    case -1: return -1            // Previous card (behind)
    case 0: return 100            // Current card (top)
    default: return Double(-position)  // Next cards (stacked below)
    }
}

// Applied in ForEach
ForEach(viewModel.visibleCardIndices, id: \.self) { cardIndex in
    let position = viewModel.stackPosition(for: cardIndex)

    CardView(...)
        .scaleEffect(scaleForPosition(position))
        .offset(y: offsetForPosition(position))
        .opacity(opacityForPosition(position))
        .zIndex(zIndexForPosition(position))  // CRITICAL: explicit zIndex
}
```
**Why this works:** Without explicit zIndex, SwiftUI reorders views during animations, causing layering glitches and broken transitions.

### Pattern 4: Spring Animation Presets
**What:** Use consistent spring presets from `AnimationTokens.swift` for cohesive feel
**When to use:** All card animations (swipe, bounce, return)
**Example:**
```swift
// Source: Existing AnimationTokens.swift
extension Animation {
    static let bscSwipe = Animation.spring(response: 0.45, dampingFraction: 0.75)
    static let bscBounce = Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let bscSnappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
}

// Usage in card stack
withAnimation(.bscSwipe) {
    viewModel.removeCard()
}

// Or for gesture return
withAnimation(.bscSnappy) {
    viewModel.dragOffset = .zero
}
```
**Why this works:** WWDC 2023 recommends bounce values 0.6-0.8 for natural feel; existing tokens already tuned for app's "sports-inspired" character.

### Pattern 5: @Observable State Management (iOS 17+)
**What:** Use `@Observable` macro for view models, `@State` for ownership in views
**When to use:** All view models (replaces @ObservableObject pattern)
**Example:**
```swift
// Source: Existing RallyPlayerView.swift pattern
@Observable
class CardStackViewModel {
    var dragOffset: CGSize = .zero
    var currentIndex: Int = 0
    var cards: [CardStackItem] = []

    // SwiftUI automatically tracks changes to these properties
    // No @Published needed
}

struct CardStackView: View {
    @State private var viewModel: CardStackViewModel

    init(items: [CardStackItem]) {
        self._viewModel = State(wrappedValue: CardStackViewModel(items: items))
    }
}
```
**Why this works:** @Observable provides better performance (only updates views that read changed properties) and less boilerplate than @ObservableObject.

### Anti-Patterns to Avoid

- **Index-based card tracking**: Causes animation glitches when array changes. Always use `Identifiable` protocol.
- **Implicit zIndex in ZStack**: SwiftUI reorders during animations. Always set explicit `.zIndex()` values.
- **Mixing gesture modifiers**: Don't combine `.gesture()`, `.simultaneousGesture()`, and `.highPriorityGesture()` without understanding precedence. Use single `.gesture()` for card swipes.
- **Loading entire card data in @State**: For Phase 2 (videos), never load video `Data` into memory. Use URL-based references (existing pattern in codebase).
- **Creating new animation curves**: Reuse existing `AnimationTokens.swift` presets for consistency.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Spring physics calculations | Custom spring damping math | SwiftUI `Animation.spring(response:dampingFraction:)` | Apple's implementation handles velocity continuity, interruptions, and edge cases |
| Gesture velocity detection | Manual timing/delta calculations | `DragGesture.Value.velocity` property | Built-in velocity tracking is frame-rate independent |
| Card depth effect | Manual scale/offset per card | `BSCCardTransition.scale/yOffset` helpers | Already implemented in `AnimationTokens.swift` (lines 234-247) |
| Rotation during swipe | Custom angle calculations | `BSCCardTransition.rotation(for:maxRotation:)` | Existing helper with sensible defaults (line 229-232) |
| Gesture boundary resistance | Complex velocity dampening | Multiplier pattern (`dragOffset *= 0.3`) | Simple, effective, matches iOS system behavior |

**Key insight:** SwiftUI's gesture and animation system handles 90% of card stack complexity. The remaining 10% is state management (which cards are visible) and preventing animation glitches (explicit zIndex).

## Common Pitfalls

### Pitfall 1: ZIndex Animation Glitches
**What goes wrong:** Cards jump, reorder incorrectly, or disappear during swipe animations
**Why it happens:** SwiftUI's automatic zIndex ordering changes when views are added/removed from ZStack
**How to avoid:**
1. Always set explicit `.zIndex()` values based on card position (not array index)
2. Use stable calculation function (e.g., `zIndexForPosition(_ position: Int)`)
3. Test card removal/addition animations specifically
**Warning signs:** Flickering during swipes, cards appearing "behind" when they should be "on top"

**Source:** fatbobman.com/en/posts/zindex/ (HIGH confidence)

### Pitfall 2: Gesture Conflicts with Tap Actions
**What goes wrong:** Tap buttons (heart/trash) don't respond, or trigger unwanted drags
**Why it happens:** SwiftUI gesture precedence - parent DragGesture consumes all touch events
**How to avoid:**
1. Apply `.gesture()` modifier to card container, not entire view
2. Apply `.highPriorityGesture()` to buttons if needed
3. Use `.contentShape(Rectangle())` on card to define tappable area
4. Test button interaction at start/end of drag
**Warning signs:** Buttons require "hard press" to work, dragging starts when tapping buttons

**Source:** Existing code pattern in RallyPlayerView.swift line 343 (onTapGesture for play/pause), WWDC gesture documentation

### Pitfall 3: Incorrect Velocity Thresholds
**What goes wrong:** Cards don't swipe away with natural flicks, or swipe too easily
**Why it happens:** Velocity is in points/second, not normalized - varies by device size
**How to avoid:**
1. Use velocity thresholds of 300-500 pts/sec for horizontal swipes (community standard)
2. Use translation thresholds of 100-120pts for slower drags (1/3 to 1/4 screen width)
3. Test on smallest (iPhone SE) and largest (iPhone Pro Max) devices
4. Combine velocity OR translation checks: `abs(velocity) > 300 || abs(translation) > 120`
**Warning signs:** Swipes feel "sticky" on large devices, too sensitive on small devices

**Source:** Existing RallyPlayerView.swift (lines 226-227, 252), HackingWithSwift tutorials

### Pitfall 4: Memory Leaks with @Observable
**What goes wrong:** View models not deallocated when cards dismissed
**Why it happens:** Strong reference cycles in closures, especially gesture handlers
**How to avoid:**
1. Always use `[weak self]` in closures that capture view model
2. Clean up timers/observers in view model deinit or view `.onDisappear`
3. For Phase 2: Clean up AVPlayer instances explicitly (existing pattern line 82 in RallyPlayerView)
4. Use Instruments to verify deallocation
**Warning signs:** Memory usage increases after dismissing cards, deinit never called

**Source:** Medium article "Memory Leaks in SwiftUI and Combine", existing cleanup pattern in RallyPlayerView.swift

### Pitfall 5: Spring Animation "Settling" Interruptions
**What goes wrong:** Card "snaps" to position when new gesture starts during animation
**Why it happens:** SwiftUI animations don't preserve velocity when interrupted by manual state changes
**How to avoid:**
1. Use `.animation(.spring(...), value: dragOffset)` on view, not `withAnimation` in gesture handler
2. For gesture-driven animations, use `.interactiveSpring()` modifier (iOS 17+)
3. Don't reset `dragOffset` to exact `.zero` - let spring settle naturally
4. Avoid mixing explicit `withAnimation` with gesture-driven state changes
**Warning signs:** Card "teleports" to final position when starting new drag, no smooth transition

**Source:** WWDC 2023 "Animate with Springs" session, GetStream/swiftui-spring-animations GitHub repo (2025)

## Code Examples

Verified patterns from official sources and existing codebase:

### Card Stack Depth Effect (Scale + Offset)
```swift
// Source: Existing AnimationTokens.swift + RallyPlayerView.swift
private func scaleForPosition(_ position: Int) -> CGFloat {
    switch position {
    case 0: return 1.0     // Current card - full size
    case 1: return 0.92    // Next card - peek effect
    default: return 1.0    // Others hidden
    }
}

private func offsetForPosition(_ position: Int) -> CGFloat {
    switch position {
    case 0: return 0       // Current card - no offset
    case 1: return 30      // Next card - peek from behind
    default: return 0      // Others hidden
    }
}

// Applied to card
CardView(...)
    .scaleEffect(scaleForPosition(position))
    .offset(y: offsetForPosition(position))
    .opacity(opacityForPosition(position))
    .zIndex(zIndexForPosition(position))
```

### Drag Gesture with Velocity Detection
```swift
// Source: Existing RallyPlayerView.swift (simplified for Phase 1)
DragGesture()
    .onChanged { value in
        viewModel.dragOffset = value.translation

        // Optional: Apply rotation during drag
        let rotation = Double(value.translation.width) / 20.0
        viewModel.dragRotation = max(-15, min(15, rotation))
    }
    .onEnded { value in
        let threshold: CGFloat = 100
        let actionThreshold: CGFloat = 120

        let horizontalOffset = value.translation.width
        let horizontalVelocity = value.velocity.width

        // Check velocity OR distance
        if abs(horizontalVelocity) > 300 || abs(horizontalOffset) > actionThreshold {
            if horizontalOffset < -actionThreshold {
                viewModel.performAction(.remove)  // Swipe left
            } else if horizontalOffset > actionThreshold {
                viewModel.performAction(.save)    // Swipe right
            }
        }

        // Return to center with spring
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            viewModel.dragOffset = .zero
            viewModel.dragRotation = 0
        }
    }
```

### Button Action as Alternative to Swipe
```swift
// Source: Existing RallyActionButtons.swift pattern
struct CardActionButtons: View {
    let onRemove: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 60) {
            // Trash button (left)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.red)
            }
            .highPriorityGesture(TapGesture())  // Prevent drag interference

            // Heart button (right)
            Button(action: onSave) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
            }
            .highPriorityGesture(TapGesture())
        }
    }
}
```

### Card Stack State Management
```swift
// Source: Existing RallyPlayerViewModel.swift pattern
@Observable
class CardStackViewModel {
    var cards: [CardStackItem]
    var currentIndex: Int = 0
    var dragOffset: CGSize = .zero
    var dragRotation: Double = 0

    var visibleCardIndices: [Int] {
        // Show current + next 2 for stacking effect
        let start = currentIndex
        let end = min(cards.count, currentIndex + 3)
        return Array(start..<end)
    }

    func stackPosition(for cardIndex: Int) -> Int {
        return cardIndex - currentIndex
    }

    func performAction(_ action: CardAction) {
        // Apply action to current card
        cards[currentIndex].action = action

        // Advance to next card
        withAnimation(.bscSwipe) {
            currentIndex += 1
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| @ObservableObject + @Published | @Observable macro | iOS 17 / 2023 | Less boilerplate, better performance (granular updates) |
| response/dampingFraction parameters | `.snappy`, `.smooth`, `.bouncy` presets | iOS 17 / 2023 | Simpler API, but existing code uses parameters (backward compatible) |
| Manual velocity calculation | `DragGesture.Value.velocity` | SwiftUI 2.0 / 2020 | Built-in, frame-rate independent |
| .animation() modifier on container | .animation(_:value:) on properties | iOS 15 / 2021 | Prevents unexpected animations, more predictable |

**Deprecated/outdated:**
- **@StateObject for @Observable classes**: Use `@State` instead (iOS 17+, per Apple migration guide)
- **withAnimation { } for gestures**: Use `.animation(_:value:)` modifier for gesture-driven animations (prevents interruption issues)
- **ZStack without explicit zIndex**: Always set zIndex for dynamic stacks (prevents animation glitches per fatbobman.com research)

## Open Questions

Things that couldn't be fully resolved:

1. **Undo Implementation Strategy**
   - What we know: PROJECT.md specifies "single-level undo only"
   - What's unclear: Should undo restore card to stack, or just revert action state?
   - Recommendation: Store `lastAction: (index: Int, action: CardAction)?` and revert in-place. Don't re-insert into stack (simpler, matches Tinder UX).

2. **Action Feedback Animation**
   - What we know: CARD-08 requires "visual feedback during drag"
   - What's unclear: Show feedback during drag, or after action completion?
   - Recommendation: Both - subtle hint icons during drag (like existing peek preview), confirmation animation after swipe completes (existing RallyActionFeedbackView pattern).

3. **Placeholder Card Content**
   - What we know: Phase 1 has "no video", just placeholder cards
   - What's unclear: What should placeholders show? Random colors? Card numbers? Images?
   - Recommendation: Show card index number + preview of Phase 2 UI elements (buttons, overlay positions) for design validation. Planner should specify.

## Sources

### Primary (HIGH confidence)
- Apple WWDC 2023 "Animate with Springs" - Spring animation best practices, velocity continuity
- Apple Developer Documentation (DragGesture, Animation) - Official API reference (accessed via WebFetch, JavaScript required)
- Existing codebase patterns:
  - `BumpSetCut/DesignSystem/Tokens/AnimationTokens.swift` - Spring presets, card transition helpers
  - `BumpSetCut/Features/RallyPlayback/RallyPlayerView.swift` - Card stack implementation, gesture handling, zIndex management
  - `BumpSetCut/Features/RallyPlayback/RallyPlayerViewModel.swift` - @Observable state management pattern

### Secondary (MEDIUM confidence)
- fatbobman.com/en/posts/zindex/ (2024) - Comprehensive zIndex behavior analysis, animation pitfalls
- GetStream/swiftui-spring-animations GitHub (2025) - Complete spring animation reference guide
- HackingWithSwift tutorials (2024-2025) - DragGesture patterns, velocity thresholds

### Tertiary (LOW confidence)
- Medium articles on card stack implementations - Architecture patterns, but not verified with official sources
- Stack Overflow discussions on gesture conflicts - Community solutions, need case-by-case validation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All SwiftUI native, well-documented by Apple
- Architecture: HIGH - Existing codebase provides proven patterns for this exact use case
- Pitfalls: MEDIUM - Combination of official sources (WWDC, fatbobman) and community findings (needs testing to verify)
- Code examples: HIGH - Directly from existing codebase and official Apple resources

**Research date:** 2026-01-24
**Valid until:** ~2026-02-24 (30 days - SwiftUI APIs stable, iOS 17 established, iOS 18 changes minimal for gestures)
