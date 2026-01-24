# Architecture Research

**Domain:** SwiftUI Card Stack Video Viewers
**Researched:** 2026-01-24
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                        │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ Card Stack  │  │  Action     │  │   Export    │          │
│  │ Container   │  │  Overlay    │  │   Sheet     │          │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
├─────────┴────────────────┴────────────────┴──────────────────┤
│                    State Management Layer                    │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Card Stack View Model                   │    │
│  │  - Card collection state (@Observable)               │    │
│  │  - Current card index                                │    │
│  │  - Action history (for undo)                         │    │
│  │  - Swipe threshold configuration                     │    │
│  └──────────────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────────┤
│                     Component Layer                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│  │ Card    │  │ Gesture │  │  Video  │  │ Action  │         │
│  │ View    │  │ Handler │  │ Player  │  │ Buttons │         │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘         │
│       │            │            │            │               │
├───────┴────────────┴────────────┴────────────┴───────────────┤
│                    Service Layer                             │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ MediaStore   │  │ VideoExporter│  │ PlayerCache  │       │
│  │ (existing)   │  │ (existing)   │  │ (existing)   │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| **CardStackContainer** | Manages Z-stack of cards, applies depth offsets, handles overall layout | ZStack with ForEach rendering cards in reverse order, applying stacked() modifier for depth effect |
| **CardView** | Individual card with video player, handles own drag gesture state | GeometryReader with offset/rotation based on drag gesture, contains video player and overlays |
| **GestureHandler** | Processes DragGesture events, determines swipe direction and threshold | DragGesture with onChanged/onEnded, calculates distance and angle for direction detection |
| **VideoPlayer** | AVPlayer wrapper with lifecycle management | Uses existing RallyVideoPlayer with RallyPlayerCache for memory-efficient playback |
| **ActionButtons** | Like/delete UI controls with undo support | Floating buttons over card or toolbar, triggers same actions as swipe gestures |
| **ActionHistoryManager** | Tracks actions for undo, manages state rollback | Array-based history with undo stack, integrates with @Observable ViewModel |
| **ExportCoordinator** | Orchestrates export workflow for selected clips | Uses existing VideoExporter service, presents share sheet or save confirmation |

## Recommended Project Structure

```
Features/
├── CardStackReview/                # New feature module
│   ├── CardStackReviewView.swift   # Main container view
│   ├── CardStackReviewViewModel.swift # @Observable state manager
│   ├── Components/
│   │   ├── SwipeableCard.swift     # Individual card with gestures
│   │   ├── CardStackContainer.swift # ZStack manager with depth effect
│   │   ├── ActionOverlay.swift     # Like/delete buttons
│   │   └── UndoButton.swift        # Undo action button
│   ├── Models/
│   │   ├── CardAction.swift        # Enum: .like, .delete, .skip
│   │   ├── ActionHistory.swift     # Undo stack data structure
│   │   └── SwipeDirection.swift    # Direction calculation
│   └── Logic/
│       ├── GestureCalculator.swift # Angle and distance calculations
│       └── ActionHistoryManager.swift # Undo/redo logic
├── RallyPlayback/                  # Existing feature
│   └── Components/
│       └── RallyVideoPlayer.swift  # Reuse for card playback
└── Export/                         # Existing feature
    └── VideoExporter.swift         # Reuse for export workflow
```

### Structure Rationale

- **Feature-based organization:** Consistent with existing BumpSetCut architecture (Features/ folder)
- **Component isolation:** SwipeableCard owns its gesture state, making it reusable and testable
- **Service reuse:** Leverages existing RallyVideoPlayer, VideoExporter, and MediaStore without duplication
- **Logic separation:** GestureCalculator and ActionHistoryManager are pure logic, easily unit-testable

## Architectural Patterns

### Pattern 1: State-Driven Card Removal

**What:** Cards are represented by an array in ViewModel state. Swipe actions modify the array, triggering SwiftUI's automatic re-render.

**When to use:** When you need simple, declarative card management with automatic animations.

**Trade-offs:**
- Pros: Simple to reason about, SwiftUI handles animations automatically, easy to implement undo
- Cons: Entire ZStack re-renders on removal (acceptable for small card counts)

**Example:**
```swift
@Observable
final class CardStackReviewViewModel {
    var cards: [RallyClip] = []
    var actionHistory: [CardAction] = []

    func handleSwipe(_ card: RallyClip, direction: SwipeDirection) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }

        let action: CardAction
        switch direction {
        case .right: action = .like(card)
        case .left: action = .delete(card)
        default: return
        }

        // Remove from stack
        cards.remove(at: index)

        // Track for undo
        actionHistory.append(action)
    }

    func undo() {
        guard let lastAction = actionHistory.popLast() else { return }

        // Restore card to top of stack
        switch lastAction {
        case .like(let card), .delete(let card):
            cards.insert(card, at: 0)
        }
    }
}
```

### Pattern 2: Gesture-Based Direction Detection

**What:** DragGesture calculates swipe angle and distance, mapping to discrete directions (left/right or 4/8-way).

**When to use:** For Tinder-style swipe interactions with directional feedback.

**Trade-offs:**
- Pros: Feels natural, provides visual feedback during drag, configurable threshold
- Cons: Requires careful tuning of thresholds to feel responsive but not too sensitive

**Example:**
```swift
struct GestureCalculator {
    let swipeThreshold: CGFloat = 200 // Distance to trigger action

    func calculateDirection(translation: CGSize) -> SwipeDirection? {
        let distance = sqrt(pow(translation.width, 2) + pow(translation.height, 2))
        guard distance > swipeThreshold else { return nil }

        let angle = atan2(translation.height, translation.width)
        let degrees = angle * 180 / .pi

        // Map angle to direction (simplified for left/right)
        if abs(degrees) < 45 {
            return .right
        } else if abs(degrees) > 135 {
            return .left
        }
        return nil
    }
}

struct SwipeableCard: View {
    let clip: RallyClip
    let onSwipe: (SwipeDirection) -> Void

    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0

    var body: some View {
        CardContent(clip: clip)
            .offset(offset)
            .rotationEffect(.degrees(rotation))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = value.translation
                        rotation = Double(value.translation.width / 20) // Subtle rotation
                    }
                    .onEnded { value in
                        let calculator = GestureCalculator()
                        if let direction = calculator.calculateDirection(translation: value.translation) {
                            onSwipe(direction)
                        } else {
                            // Snap back
                            withAnimation(.spring()) {
                                offset = .zero
                                rotation = 0
                            }
                        }
                    }
            )
    }
}
```

### Pattern 3: Cached Video Player per Card

**What:** Use existing RallyPlayerCache to manage AVPlayer instances, one per visible card (typically top 3-4 cards).

**When to use:** For smooth video playback without memory leaks or initialization lag.

**Trade-offs:**
- Pros: Players are pre-initialized, smooth transitions, automatic cleanup
- Cons: Memory usage grows with cache size (mitigated by limiting visible cards)

**Example:**
```swift
struct CardStackContainer: View {
    let clips: [RallyClip]
    @StateObject private var playerCache = RallyPlayerCache()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(clips.prefix(4).indices.reversed(), id: \.self) { index in
                    SwipeableCard(
                        clip: clips[index],
                        isActive: index == clips.startIndex, // Only top card is active
                        playerCache: playerCache
                    )
                    .stacked(at: index) // Apply depth offset
                }
            }
        }
        .onDisappear {
            playerCache.cleanup() // Existing cleanup logic
        }
    }
}

extension View {
    func stacked(at position: Int) -> some View {
        let offset = CGFloat(position * 10) // 10pt offset per card
        let scale = 1.0 - (CGFloat(position) * 0.05) // Subtle scale reduction

        return self
            .offset(y: offset)
            .scaleEffect(scale)
    }
}
```

## Data Flow

### Swipe Action Flow

```
[User Swipe Gesture]
    ↓
[GestureCalculator] → Calculates direction and distance
    ↓
[SwipeableCard] → Triggers onSwipe callback
    ↓
[CardStackReviewViewModel] → Updates card array, records action
    ↓ (SwiftUI observation)
[CardStackContainer] → Re-renders ZStack with new card list
    ↓
[RallyPlayerCache] → Releases player for removed card
```

### Like/Delete Action Flow

```
[Action Button Tap]
    ↓
[ActionOverlay] → Calls viewModel.performAction(.like/.delete)
    ↓
[CardStackReviewViewModel] → Removes card from array
    ↓
[ActionHistory] → Records action for undo
    ↓
[MediaStore] → Updates metadata (isLiked, isDeleted flags)
    ↓ (notification)
[Library] → Reflects changes if user navigates back
```

### Undo Flow

```
[Undo Button Tap]
    ↓
[ActionHistoryManager] → Pops last action from stack
    ↓
[CardStackReviewViewModel] → Inserts card back at index 0
    ↓ (SwiftUI observation)
[CardStackContainer] → Animates card back into stack
    ↓
[RallyPlayerCache] → Recreates player for restored card
```

### Export Flow

```
[Export Button Tap]
    ↓
[ExportCoordinator] → Collects liked clips
    ↓
[VideoExporter] → Calls exportRallySegments() (existing logic)
    ↓
[AVAssetExportSession] → Stitches clips together
    ↓
[Share Sheet] → Presents system share UI
```

### Key Data Flows

1. **Card state is source of truth:** ViewModel's `cards` array drives entire UI. Removal is immediate, undo is insertion.
2. **Gesture calculations are pure functions:** GestureCalculator has no state, just math. Easily testable.
3. **Player cache lifecycle is decoupled:** RallyPlayerCache manages AVPlayer lifecycle independently. CardStack only passes URLs.
4. **MediaStore integration is async:** Metadata updates (like/delete flags) happen asynchronously. Card removal doesn't wait for MediaStore.

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 10-50 clips | Current architecture is ideal. In-memory card array, no pagination needed. |
| 50-200 clips | Consider lazy loading: only load metadata for top 20 cards, fetch more as stack depletes. |
| 200+ clips | Implement pagination: fetch clips in batches of 50, preload next batch when 10 cards remain. |

### Scaling Priorities

1. **First bottleneck:** Memory usage from AVPlayer instances. **Fix:** Limit RallyPlayerCache to 4 players maximum (existing pattern already handles this).
2. **Second bottleneck:** Initial load time for large clip arrays. **Fix:** Load first 20 clips immediately, fetch rest in background Task. Show spinner if user reaches end of loaded clips.

## Anti-Patterns

### Anti-Pattern 1: Managing Card State in Individual Card Views

**What people do:** Each SwipeableCard maintains its own @State for whether it's removed, trying to coordinate removal via Bindings.

**Why it's wrong:**
- Creates distributed state that's hard to reason about
- Makes undo nearly impossible (can't restore a view that's been removed)
- Breaks SwiftUI's unidirectional data flow

**Do this instead:** Keep `cards` array in ViewModel as single source of truth. Cards are dumb views that render based on data passed down.

### Anti-Pattern 2: Loading All AVPlayers Upfront

**What people do:** Create AVPlayer for every clip in the stack immediately.

**Why it's wrong:**
- Massive memory footprint (each AVPlayer holds video buffer in memory)
- Slow initialization (blocks UI thread)
- Most players never used (user may swipe away before reaching later cards)

**Do this instead:** Use RallyPlayerCache pattern (already exists in codebase). Cache limits to top 3-4 cards, lazy-loads players on-demand.

### Anti-Pattern 3: Complex Animation State Machines

**What people do:** Track animation state (.dragging, .snapping, .removing) in separate @State variables, manually coordinating transitions.

**Why it's wrong:**
- Hard to debug (state machine bugs are subtle)
- Animations can get stuck in intermediate states
- Lots of code for simple use case

**Do this instead:** Let SwiftUI handle animation automatically. Use `.animation(.spring())` on offset/rotation modifiers. On swipe completion, just remove from array—SwiftUI animates the rest.

### Anti-Pattern 4: Reimplementing Export Logic

**What people do:** Copy-paste export code into CardStackReviewViewModel, creating duplicate logic.

**Why it's wrong:**
- Code duplication (violates DRY)
- Bugs must be fixed in multiple places
- Export behavior diverges over time

**Do this instead:** Inject existing VideoExporter service into ViewModel. Call `exportRallySegments()` or `exportStitchedRalliesToPhotoLibrary()` directly.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| **AVFoundation** | Via RallyVideoPlayer wrapper | Already exists, wraps AVPlayer with lifecycle management |
| **Photos Framework** | Via VideoExporter | Already exists, handles PHPhotoLibrary permissions and export |
| **MediaStore** | Direct dependency injection | Existing service for metadata persistence |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| **CardStackReviewViewModel ↔ MediaStore** | Direct method calls, NotificationCenter for updates | ViewModel calls MediaStore.updateMetadata(), listens for .libraryContentChanged |
| **SwipeableCard ↔ RallyVideoPlayer** | Property injection (URL, isActive, playerCache) | Card passes URL and cache to player, player manages its own lifecycle |
| **CardStackReviewViewModel ↔ VideoExporter** | Async method calls | ViewModel calls `await exporter.exportStitchedRalliesToPhotoLibrary()`, shows loading UI during export |
| **CardStackContainer ↔ ActionOverlay** | Closure callbacks | Overlay calls `onLike`/`onDelete` closures passed from parent ViewModel |

## Integration with Existing Architecture

### Leveraging Existing Patterns

1. **Feature-based modules:** CardStackReview fits naturally as a new feature under `Features/`
2. **@Observable ViewModels:** Consistent with existing MVVM pattern (LibraryViewModel, etc.)
3. **MediaStore as source of truth:** CardStackReview reads from MediaStore, doesn't introduce parallel data layer
4. **RallyVideoPlayer reuse:** No need to rebuild video playback logic—just wrap existing player
5. **VideoExporter reuse:** Export workflow already handles stitching, orientation, photo library access

### New Components Required

1. **CardStackContainer:** New component, but follows ZStack + ForEach pattern used elsewhere
2. **GestureCalculator:** New pure-function utility for angle/distance math
3. **ActionHistoryManager:** New component for undo functionality (not present elsewhere in app)

## Build Order Recommendations

Based on component dependencies:

### Phase 1: Core Card Stack (No Video)
**Build:** CardStackContainer, SwipeableCard with placeholder content (colored rectangles)
**Test:** Swipe gestures, card removal animations, depth stacking effect
**Why first:** Validates core interaction without video complexity

### Phase 2: State Management
**Build:** CardStackReviewViewModel, ActionHistory, GestureCalculator
**Test:** Card removal updates state, undo restores cards, direction detection accuracy
**Why second:** State layer must work before integrating video playback

### Phase 3: Video Playback Integration
**Build:** Integrate RallyVideoPlayer into SwipeableCard, wire up playerCache
**Test:** Top card plays video, swiped cards stop playback, memory usage stays stable
**Why third:** Builds on validated gesture/state foundation

### Phase 4: Action Buttons & Undo
**Build:** ActionOverlay, UndoButton, wire to ViewModel
**Test:** Buttons trigger same actions as swipes, undo reverses actions
**Why fourth:** Alternative input method, depends on working state management

### Phase 5: Export Integration
**Build:** ExportCoordinator, wire to existing VideoExporter
**Test:** Export workflow completes, video saves to Photos, share sheet works
**Why last:** End-to-end feature, depends on all prior components working

## Sources

- **SwiftUI Card Stack Patterns:** GitHub repositories (dadalar/SwiftUI-CardStackView, tobi404/SwipeCardsKit) showing declarative API patterns and state management approaches (MEDIUM confidence - community libraries, not official Apple docs)
- **DragGesture Implementation:** Official Apple documentation and community tutorials (Hacking with Swift, Design+Code) on DragGesture patterns with onChanged/onEnded handlers (HIGH confidence - verified against official SwiftUI docs)
- **AVPlayer Memory Management:** Recent 2025 Medium articles on AVPlayer lifecycle in SwiftUI, emphasizing cleanup in onDisappear and player reuse patterns (MEDIUM confidence - best practices from experienced developers)
- **SwiftUI Undo/Redo Patterns:** February 2025 articles on using @Environment(\.undoManager) and custom undo stacks with @Observable (HIGH confidence - recent, multiple sources agree)
- **Existing BumpSetCut codebase:** Direct analysis of RallyVideoPlayer, VideoExporter, MediaStore, LibraryView patterns (HIGH confidence - actual project code)

---
*Architecture research for: SwiftUI Card Stack Video Viewers*
*Researched: 2026-01-24*
