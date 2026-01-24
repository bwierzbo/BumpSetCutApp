# Pitfalls Research

**Domain:** SwiftUI Card Stack Video Viewers
**Researched:** 2025-01-24
**Confidence:** HIGH

## Critical Pitfalls

### Pitfall 1: AVPlayer Memory Leaks from NotificationCenter Observers

**What goes wrong:**
AVPlayer instances are retained in memory indefinitely because NotificationCenter observers create strong reference cycles. Memory accumulates rapidly when swiping through multiple video cards, eventually causing the app to crash or be terminated by the OS.

**Why it happens:**
Developers add observers for playback completion (e.g., `.AVPlayerItemDidPlayToEndTime`) without using `[weak self]` capture lists or without removing observers before deallocating the player. The iOS 17 regression with `@State` property wrapper storing reference types (including AVPlayer) exacerbates this issue.

**How to avoid:**
1. **Always use weak references** in observer closures: `[weak player]` or `[weak self]`
2. **Store observer tokens** and remove them explicitly before cleanup
3. **Replace player items with nil** before deallocating: `player.replaceCurrentItem(with: nil)`
4. **Pause before cleanup**: `player.pause()` before setting player to nil
5. **Implement proper cleanup lifecycle**: Remove observers → pause players → replace items → clear dictionary

**Warning signs:**
- Memory footprint grows continuously while swiping through cards
- Instruments shows AVPlayer instances not being deallocated
- App crashes with memory pressure warnings after viewing 10-20 videos
- Multiple AVPlayer instances visible in memory graph despite only 1-2 being displayed

**Phase to address:**
Phase 1 (Core Card Stack) - Set up proper lifecycle management from the start. This is foundational and cannot be retrofitted easily.

---

### Pitfall 2: Gesture Conflicts Between Card Swipe and Video Player Tap

**What goes wrong:**
DragGesture on the card stack prevents tap gestures on the video player from working, or vice versa - taps intended for play/pause trigger card swipes, or swipes fail because tap gestures intercept them. In iOS 18, switching from `.gesture()` to `.simultaneousGesture()` causes both gestures to fire simultaneously, creating chaotic "dancing" UI where the card scrolls while being dragged.

**Why it happens:**
SwiftUI's gesture system has a priority hierarchy that changes between iOS versions. Multiple gesture recognizers compete for the same touch events without explicit priority or coordination. The default gesture behavior doesn't distinguish between intentional taps and the start of a drag motion.

**How to avoid:**
1. **Use `.highPriorityGesture()`** for the dominant gesture (usually card swipe)
2. **Add empty onTapGesture** before other gestures as a workaround to prevent conflicts
3. **Disable video player interactions** during drag: `.disabled(isDragging)` or use explicit tap threshold
4. **Apply gestures at correct view level**: Card swipe on card container, tap on video player layer
5. **Test on multiple iOS versions** - iOS 17 vs iOS 18 behavior differs significantly

**Warning signs:**
- Taps on video don't pause/play, but trigger swipe animations
- Short swipes fail to register because tap gesture captures them
- Gesture behavior differs between device orientations
- Behavior changes after iOS update without code changes

**Phase to address:**
Phase 1 (Core Card Stack) - Gesture system must be architected correctly from the beginning. Difficult to refactor once animation timing is established.

---

### Pitfall 3: ZIndex Animation Bugs with Dynamic Card Stacks

**What goes wrong:**
When cards are added/removed from the stack, SwiftUI reorders views in the ZStack causing cards to "jump" positions, fly in from wrong directions, or disappear without animation. The topmost card suddenly appears behind other cards during swipe animations, breaking the illusion of a physical card stack.

**Why it happens:**
SwiftUI recalculates zIndex for views with undefined or computed zIndex values during state changes. When using `ForEach` with indices that shift after deletion (e.g., removing card 0 makes card 1 become card 0), the zIndex mapping becomes unstable. The zIndex modifier is **not animatable**, so changes happen instantly even within animation blocks.

**How to avoid:**
1. **Use stable, explicit zIndex values** tied to stable identifiers (not array indices)
2. **Calculate zIndex from stack position relative to current card**, not from array position
3. **Never rely on implicit zIndex** (all zeros) - always set explicitly for stacked views
4. **Maintain stable view identity** during transitions - don't swap components
5. **Use view position in stack** as zIndex: `currentIndex - cardIndex` gives stable layering

**Warning signs:**
- Cards appear to swap layer order mid-animation
- Delete animations show cards jumping from wrong positions
- Stack order becomes inconsistent after several swipes
- Animations work in portrait but break in landscape (different view hierarchy)

**Phase to address:**
Phase 1 (Core Card Stack) - ZIndex architecture must be correct from day one. Cannot be fixed without potentially rewriting animation system.

---

### Pitfall 4: Orientation Change Video Player Crashes

**What goes wrong:**
App crashes or freezes when device orientation changes while playing video. Video player shows black screen after rotation. Audio continues playing but video freezes on last frame. AVPlayer seek operations fail silently after orientation change.

**Why it happens:**
AVPlayer maintains references to the original video layer size and transform. When the view geometry changes dramatically during rotation, the player doesn't automatically adjust. Concurrent seek operations during rotation can corrupt player state. The video layer's `videoGravity` becomes mismatched with the new aspect ratio.

**How to avoid:**
1. **Calculate orientation once** per view update and cache the result - don't query repeatedly
2. **Use contentMode from orientation**, not reactive updates: `.aspectRatio(contentMode: isPortrait ? .fit : .fill)`
3. **Pause seeking during orientation transitions** - queue seeks to execute after rotation completes
4. **Don't recreate players on orientation change** - reuse existing player and adjust frame only
5. **Test rapid rotation** - 3-4 quick rotations back and forth should not crash

**Warning signs:**
- Console shows AVPlayer warnings during rotation
- Video becomes black screen after 2nd or 3rd rotation
- Memory spikes during orientation changes
- Crashes only occur on physical devices, not simulator (timing differences)

**Phase to address:**
Phase 2 (Video Integration) - Must be addressed when integrating AVPlayer, before animation polish. Orientation handling affects player lifecycle design.

---

### Pitfall 5: CMTime Seeking Race Conditions with Rally Segments

**What goes wrong:**
Seeking to rally segment start times fails intermittently - video plays from wrong timestamp or shows black screen. Multiple rapid swipes cause seeks to execute out of order, showing rally N+2 when user intended rally N. Seek operations take several seconds on device despite being instant in simulator.

**Why it happens:**
The default `seek(to:)` API doesn't cancel previous seeks - they queue up and execute sequentially, causing the player to "chase" through multiple positions. When using zero tolerance for frame-accurate seeking, iOS must decode precisely which is slow. Rally segment URLs with fragment identifiers (`#rally_0`) confuse some AVFoundation internals that cache based on URL.

**How to avoid:**
1. **Use `seek(to:toleranceBefore:toleranceAfter:)` with reasonable tolerance** except when frame-accuracy is critical
2. **Call seek with completion handler** to know when safe to play: `seek(to:) { [weak self] finished in ... }`
3. **Throttle rapid seeks** - debounce or ignore seek requests during active seek operation
4. **Separate base URL from fragment** when creating AVPlayerItem - use base URL only
5. **Seek twice for precision**: First with tolerance for speed, then without for accuracy

**Warning signs:**
- Video shows black screen for 1-2 seconds after swipe
- Seeking is instant in simulator but 3-5 seconds on device
- Rally segment shows wrong portion of source video
- Console shows "seeking to X while still seeking to Y" warnings

**Phase to address:**
Phase 2 (Video Integration) - Critical for rally segment playback. Affects perceived responsiveness of card swipes.

---

### Pitfall 6: Background/Foreground State Persistence Failure

**What goes wrong:**
User swipes to rally 5, backgrounds the app, returns 10 minutes later - app shows rally 0 or crashes. Playback state (play/pause, current time, saved/deleted status) is lost. User's undo stack disappears after app backgrounding. When returning to foreground, videos auto-play unexpectedly or remain frozen.

**Why it happens:**
SwiftUI views can be torn down when app backgrounds, losing `@State` that isn't explicitly persisted. AVPlayer pauses automatically on background transition but doesn't resume intelligently on foreground. NotificationCenter observers for lifecycle events (`didEnterBackground`, `didBecomeActive`) are added but not triggered reliably in all scenarios.

**How to avoid:**
1. **Persist critical state to UserDefaults/file** when backgrounding: current index, saved rallies, removed rallies
2. **Subscribe to app lifecycle notifications** using Combine publishers for reliable delivery
3. **Pause explicitly on background** and restore play state on foreground based on saved state
4. **Don't auto-play on foreground** - wait for explicit user interaction
5. **Clear undo stack on background** or persist it explicitly - don't leave in inconsistent state

**Warning signs:**
- Manual testing: background → wait 5 min → foreground shows wrong state
- User complaints about "losing progress" in rally review
- Videos start playing audio unexpectedly when app regains focus
- State inconsistencies only occur after backgrounding (not during normal use)

**Phase to address:**
Phase 3 (State Management) - Add after core functionality works. Requires testing scenarios that don't appear in normal development flow.

---

### Pitfall 7: Thumbnail Generation Blocking Main Thread

**What goes wrong:**
UI freezes for 1-3 seconds when swiping to new card while thumbnail is being extracted. The "peek preview" animation stutters because thumbnail generation blocks gesture updates. App shows "spinning wheel" on older devices when preloading adjacent card thumbnails.

**Why it happens:**
AVAssetImageGenerator's `copyCGImage()` runs synchronously on the calling thread. Developers call it on main thread thinking it's fast, but seeking to specific timestamps in large video files requires disk I/O and decoding. The deprecated iOS 18 API `copyCGImage()` is being replaced with `generateCGImageAsynchronously()`, but the async version has priority inversion issues - it runs on Default QoS thread while UI thread waits with semaphore.

**How to avoid:**
1. **Always use `generateCGImageAsynchronously()`** on background queue, not `copyCGImage()`
2. **Extract thumbnails in ViewModel on background thread** using `Task` or `DispatchQueue.global(qos: .userInitiated)`
3. **Set `maximumSize`** to reasonable dimensions (e.g., 720p) - don't extract full 4K frames
4. **Preload thumbnails during idle time**, not during active gestures
5. **Show placeholder immediately** while thumbnail extracts in background

**Warning signs:**
- Instruments shows main thread blocked in `AVAssetImageGenerator`
- Frame rate drops below 60fps during swipe with peek preview
- Different performance on simulator (fast) vs device (slow)
- Console warnings about "Priority inversion" or QoS issues

**Phase to address:**
Phase 4 (Peek Preview) - Only becomes critical when adding peek preview feature. Core card stack doesn't need thumbnails.

---

### Pitfall 8: Audio Session Conflicts with Multiple AVPlayers

**What goes wrong:**
When swiping from card A to card B, both videos play audio simultaneously. After playing 3-4 videos, audio stops working entirely. Audio from backgrounded app (Music, podcast) stops unexpectedly when opening rally viewer. Device audio controls (volume buttons, Control Center) don't affect video playback.

**Why it happens:**
AVAudioSession is a **global singleton** - only one configuration active at a time. Setting `.playback` category with `setActive(true)` stops all other audio on device. Each AVPlayer activates the audio session independently without coordination. Multiple players don't automatically duck or mute when another starts playing.

**How to avoid:**
1. **Configure audio session once** at app/scene level, not per-player
2. **Use single shared audio session** for all players: configure in AppDelegate or first player only
3. **Pause previous player before playing next** - only one plays at a time
4. **Deactivate with `notifyOthersOnDeactivation: true`** to allow background audio to resume
5. **Don't call `setActive(true)` repeatedly** - set once and leave active while viewing rallies

**Warning signs:**
- Multiple videos audible at once during swipe transitions
- Console: "AVAudioSession: Deactivating an audio session that has running I/O"
- Background music (Spotify, Apple Music) stops when opening rally player
- Audio works for first 2-3 cards then stops

**Phase to address:**
Phase 2 (Video Integration) - Must be architected correctly when adding first AVPlayer. Cannot easily retrofit coordination later.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Using `.gesture()` instead of `.highPriorityGesture()` | Less code, simpler | Gesture conflicts in iOS updates, inconsistent behavior across versions | Never - always be explicit |
| Storing AVPlayer in `@State` | Works in SwiftUI, feels natural | iOS 17 memory leak regression, not properly cleaned up | Never - use explicit lifecycle management |
| Calling `seek(to:)` without tolerance | Frame-accurate positioning | Extremely slow on device (3-5 sec), blocks during rapid swipes | Only for final precision seek after user stops |
| Using array indices for `zIndex` | Easy to calculate | Breaks when items removed, animations fail unpredictably | Never - use stable identifiers |
| Auto-playing video on `onAppear` | Immediate playback, smooth UX | Conflicts with state restoration, multiple videos play simultaneously | Only after explicit state check (not backgrounded, is current card) |
| Loading full-resolution thumbnails | Best quality previews | Main thread blocked 1-3 sec, memory bloat | Never - always downscale with `maximumSize` |
| Single `@State` view model instance | Simple architecture | Lost on backgrounding, doesn't persist user progress | MVP only - add persistence by Phase 3 |
| Removing observers in `deinit` only | Automatic cleanup | `deinit` never called due to retention cycles, leaks accumulate | Never - use explicit `cleanup()` method |

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Caching unlimited AVPlayer instances | First 10 videos smooth | Memory pressure crashes, 200+ MB per cached player | 5-10 cached players (1-2 GB RAM) |
| Preloading all thumbnails eagerly | Nice UX for first few cards | Memory bloat, slow initial load | 20+ rally segments (100+ MB thumbnail cache) |
| Creating new player for each card view | Simple code, no cache management | Seek to start time takes 1-2 sec per card, stuttery swipes | Normal usage - always hurts UX |
| Synchronous thumbnail extraction | Works in simulator | 3-5 sec freeze on device per thumbnail | First device test - simulator is 10x faster |
| Not limiting visible card stack | Show all cards for "peek" effect | SwiftUI renders 50+ video layers, drops to 15fps | 10+ cards in stack - render cost adds up |
| Uniform animation duration for all swipes | Consistent feel | Feels wrong with velocity - slow swipes too fast, fast swipes too slow | Users notice on first use - breaks physical intuition |

## UX Pitfalls

Common user experience mistakes in this domain.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Auto-playing on app foreground | Startles user, wastes battery, unexpected audio in public | Require explicit tap to resume playback after backgrounding |
| No visual feedback during thumbnail load | User sees black card, thinks app crashed | Show placeholder or loading spinner immediately |
| Instant card transitions without velocity | Feels robotic, ignores swipe speed | Use `value.velocity` to adjust animation duration (faster swipe = faster animation) |
| Same animation for "remove" and "save" | User can't tell which action happened | Different directions (left vs right) and different colors/icons |
| No undo for destructive actions | User accidentally swipes wrong direction, rally lost forever | Always provide undo for delete/remove actions |
| Orientation lock during video playback | User must rotate device back to see other content | Support both orientations, change video aspect ratio only |
| Playing deleted rallies again | User swipes "remove", confused when it appears in next session | Persist removed rallies and filter from playback |

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **AVPlayer cleanup:** Observers removed in `cleanup()` — verify no retain cycles in Instruments memory graph
- [ ] **Gesture testing:** Card swipe works — verify tap-to-pause still works during/after drag gesture
- [ ] **ZIndex stability:** Animations smooth in testing — verify deletion doesn't cause layer swapping or jumpy transitions
- [ ] **Orientation support:** Rotates correctly — verify rapid 3-4 rotations don't crash or freeze video
- [ ] **Segment seeking:** Rally starts at correct time — verify on device (not just simulator), test 10+ rapid swipes
- [ ] **State persistence:** Current rally tracked — verify survives backgrounding for 5+ minutes
- [ ] **Thumbnail performance:** Peek preview shows thumbnail — verify extracted async on background queue, not blocking main thread
- [ ] **Audio session:** Video plays with audio — verify doesn't stop background music, only one video audible at once
- [ ] **Memory management:** No crashes during testing — verify memory stable after 50+ card swipes in Instruments
- [ ] **Undo implementation:** Undo button exists — verify undo state survives navigation away and back, cleared on background

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| AVPlayer memory leaks | MEDIUM | Add cleanup audit pass - use Instruments to find all AVPlayer instances, add explicit cleanup calls, verify with leak detection |
| Gesture conflicts | HIGH | May require gesture architecture refactor - extract to separate modifier, use `.updating` gesture state, test on multiple iOS versions |
| ZIndex animation bugs | HIGH | Requires animation system redesign - switch to stable identifier-based zIndex, may need to change ForEach to explicit views |
| Orientation crashes | MEDIUM | Add orientation state management - pause seeks during transition, debounce rapid rotations, cache orientation calculation |
| Seek race conditions | LOW | Add seek throttling layer - track in-flight seeks, cancel or queue new requests, use completion handlers |
| State persistence failure | LOW | Add persistence layer - create Codable state model, save on background notification, restore on appear |
| Thumbnail blocking main thread | LOW | Move to background queue - wrap in Task, update @Published thumbnail property on main thread |
| Audio session conflicts | MEDIUM | Centralize audio session management - move to app-level service, coordinate player activation/deactivation |

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| AVPlayer memory leaks | Phase 1: Core Card Stack | Instruments allocation profile shows stable memory after 50 swipes |
| Gesture conflicts | Phase 1: Core Card Stack | Swipe + tap gestures both work in iOS 17 and iOS 18 devices |
| ZIndex animation bugs | Phase 1: Core Card Stack | Delete card shows smooth animation, no layer swapping visible |
| Orientation crashes | Phase 2: Video Integration | Rapid rotation 5x while playing video doesn't crash or freeze |
| Seek race conditions | Phase 2: Video Integration | 10 rapid swipes in 5 seconds all seek to correct rally start times |
| State persistence failure | Phase 3: State Management | Background 10 min → foreground restores exact rally index and saved/removed state |
| Thumbnail blocking main thread | Phase 4: Peek Preview | Time Profiler shows no main thread blocks during thumbnail extraction |
| Audio session conflicts | Phase 2: Video Integration | Only one video audible at once, background music resumes on app exit |

## Sources

**Web Search (2025 resources):**
- SwiftUI AVPlayer memory leaks: [Apple Developer Forums - iOS 17 @State regression](https://www.hackingwithswift.com/forums/swiftui/swiftui-videoplayer-leaking-atstate-management-issue/25070)
- Gesture conflicts: [Apple Developer Forums - DragGesture iOS 18 changes](https://developer.apple.com/forums/thread/774305)
- Card stack animations: [Medium - SwiftUI Animations 2025](https://medium.com/@bhumibhuva18/swiftui-animations-in-2025-beyond-basic-transitions-f63db40c7c46)
- Orientation handling: [Polpiella - Changing orientation for single screen](https://www.polpiella.dev/changing-orientation-for-a-single-screen-in-swiftui/)
- AVPlayer seeking: [Medium - Mastering SwiftUI and AVPlayer Integration](https://medium.com/@tokusha.aa/mastering-swiftui-and-avplayer-integration-a-complete-guide-to-timecodes-and-advanced-playback-6ef9a88b3b8d)
- ZIndex layering: [Medium - Mastering SwiftUI's zIndex](https://fatbobman.medium.com/mastering-swiftuis-zindex-a-comprehensive-guide-5ebdf5588365)
- Thumbnail generation: [Medium - iOS 18 Video Thumbnail](https://medium.com/@zawwinmyat.dev/generate-video-thumbnail-without-the-need-to-open-video-in-ios-18-0-using-avkit-and-swift-1938b3941339)
- Audio session management: [Mux - Background audio handling](https://www.mux.com/blog/background-audio-handling-with-ios-avplayer)

**Codebase analysis:**
- Existing RallyPlayerView.swift shows good patterns: stable zIndex calculation, explicit player cache, thumbnail preloading
- RallyPlayerCache.swift demonstrates proper cleanup: observer removal before player deallocation, `replaceCurrentItem(with: nil)`
- RallyThumbnailCache.swift shows async extraction pattern with Task-based preloading
- VideoPlayerView.swift has potential issue: calls `setActive(true)` per instance instead of shared session

---
*Pitfalls research for: SwiftUI Card Stack Video Viewers*
*Researched: 2025-01-24*
