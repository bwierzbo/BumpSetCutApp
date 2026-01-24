# Feature Research: Swipeable Card Video Viewer

**Domain:** Short-form video card stack interfaces (Tinder-style swipe + TikTok-style video playback)
**Researched:** 2026-01-24
**Confidence:** MEDIUM

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete or broken.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Swipe left/right gestures** | Core metaphor from Tinder/Reels. Users intuit: swipe = binary choice | MEDIUM | Requires gesture recognizers, drag state tracking, threshold detection |
| **Tap action buttons as alternative** | Accessibility + one-handed use. Not everyone can/wants to swipe | LOW | Tinder has both swipe and buttons. Must mirror swipe actions exactly |
| **Visual feedback during drag** | Users need to see card following finger, hint at direction/action | MEDIUM | Card rotation, translation during drag. Color/icon hints for actions |
| **Spring physics on release** | Feels "broken" without natural physics. Card should bounce/settle realistically | MEDIUM | SwiftUI spring animations with stiffness/damping tuned for snappy but natural feel |
| **Immediate video autoplay** | TikTok/Reels train users: video starts when visible, no play button needed | MEDIUM | Auto-play on card reveal, loop seamlessly. Muted isn't expected for user's own content |
| **Seamless video looping** | Short clips (3-15s) must loop without visible restart. Jarring gap = poor quality | LOW | Use AVPlayer loop, ensure restart <24ms. Modern browsers do this well |
| **Smooth orientation transitions** | iOS users rotate devices constantly. Video/UI must adapt without breaking playback | HIGH | Portrait: fit video, buttons at bottom. Landscape: fill screen, reposition buttons. No player reset |
| **Last card awareness** | Users need to know when stack ends. Empty state or "no more cards" feedback | LOW | Show indicator when reaching last card. Prevent confusing infinite scroll feeling |
| **Action reversibility (undo)** | Accidental swipes are common. 1-level undo is table stakes for swipe interfaces | MEDIUM | Single undo with reverse animation. Tinder/Bumble standard. More levels = unnecessary complexity |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable for BumpSetCut's use case.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Page-peel animation** | More tactile/satisfying than slide. Reinforces "card stack" metaphor vs infinite scroll | HIGH | Custom animation beyond standard SwiftUI. 60fps target. CPU/GPU intensive |
| **Batch export with visual selection** | Volleyball coaches need compilation videos. Tinder/Reels are view-only | MEDIUM | Checkbox selection UI. Export individual or stitched. Most swipe apps don't have multi-export |
| **Select all/deselect all toggle** | Quick curation when most clips are good (or bad). Saves time vs one-by-one | LOW | Standard list manipulation. Big QoL for users with 20+ rally clips |
| **Explicit like/delete actions** | Most Tinder clones only have "like" equivalent. Deleting clips during review is valuable | LOW | Two actions instead of one. Undo prevents regret. Reduces post-review cleanup |
| **Empty state with parent video option** | If no clips liked, user can delete source video from same screen. Reduces navigation | LOW | Contextual action. Saves trip back to library. Not seen in typical swipe apps |
| **Haptic feedback on actions** | iOS 26 users expect gentle haptics on swipes (Apple Music standard). Adds polish | LOW | UIImpactFeedbackGenerator .medium on swipe complete, .light on button tap |
| **Swipe threshold customization** | Some users want hair-trigger, others want deliberate swipes. Preferences prevent frustration | LOW | Hidden in settings. Advanced feature. Not many swipe apps expose this |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems in this context.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Multi-level undo (>1 action)** | "What if I make multiple mistakes?" | Adds UI complexity (undo history stack), confuses state management, rarely used beyond 1 level. Tinder doesn't have it | Single undo + clear visual feedback during swipe prevents most mistakes |
| **Delete confirmation dialogs** | "Prevent accidental deletion" | Slows workflow dramatically. User must confirm every delete = friction. Kills swipe flow | Undo provides safety net. Visual feedback (red overlay, trash icon) during swipe is warning enough |
| **Reorder clips in export** | "I want clips in specific order" | Complex drag-drop UI. Requires rethinking card stack (no longer chronological). Most users don't care about order | Export clips in original video timestamp order. If reorder needed, use external editor |
| **In-app video trimming** | "Clip is too long/has dead time" | Scope creep. Becomes video editor, not rally reviewer. Trim UI is complex (timeline scrubber, handles) | AI detection should already produce good clip boundaries. Re-process video if detection is bad |
| **Swipe up/down for other actions** | "More gestures = more features" | Cognitive load. TikTok uses vertical swipe for navigation between videos, not actions. Conflicts with scroll | Left/right + undo covers 99% of use cases. Keep it simple |
| **Share individual clips to social** | "I want to post to Instagram" | Privacy/workflow mismatch. Volleyball footage often includes minors (permission issues). Export to camera roll → user shares manually | Export to camera roll, let user handle sharing. App stays out of social media integration |
| **Real-time processing feedback on cards** | "Show detection confidence score on each clip" | Info overload during fast review. Users just want good clips, not ML debugging | Hide technical details. If clip quality is bad, it won't get liked. Keep UI clean |

## Feature Dependencies

```
[Swipe gesture recognition]
    └──requires──> [Spring physics animation]
                       └──requires──> [Visual drag feedback]

[Undo action]
    └──requires──> [Action history tracking (1 level)]
                       └──requires──> [Reverse animation for card restoration]

[Batch export]
    └──requires──> [Like action persistence]
    └──requires──> [Multi-clip selection UI]
                       └──enhances──> [Select all/deselect all]

[Video autoplay] ──requires──> [Seamless loop]

[Orientation transitions] ──enhances──> [Video autoplay] (must maintain playback state)

[Page-peel animation] ──conflicts──> [Simple slide animation] (choose one)

[Haptic feedback] ──enhances──> [Swipe gesture] (optional polish)
```

### Dependency Notes

- **Swipe gesture requires spring physics:** Without natural physics, swipe feels "sticky" or "broken." Spring animation gives tactile realism.
- **Undo requires action history:** Must track last action (like/delete) and restore previous card state. More than 1 level = unnecessary complexity.
- **Batch export requires like persistence:** Can't export liked clips if like state isn't persisted. Must survive app restart.
- **Video autoplay requires seamless loop:** Short clips (5-20s rallies) look amateur if loop has visible gap. Must restart <24ms.
- **Orientation transitions enhance autoplay:** If orientation change stops video, user experience breaks. Must preserve AVPlayer state.
- **Page-peel conflicts with slide:** Can't do both. Page-peel is higher fidelity but more complex. Slide is simpler fallback.

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to validate the swipe-to-curate workflow.

- [x] **Swipe left (delete) / right (like) gestures** — Core metaphor. Without this, not a "swipe interface"
- [x] **Tap buttons as swipe alternative** — Accessibility + fallback
- [x] **Visual feedback during drag** — Card follows finger, rotates, shows action hint
- [x] **Spring physics on release** — Natural feel. Non-negotiable
- [x] **Single-level undo** — Safety net for mistakes
- [x] **Video autoplay with seamless loop** — Expected from TikTok/Reels experience
- [x] **Portrait/landscape orientation support** — iOS users expect this
- [x] **Batch export screen** — Checkbox selection, individual or stitched export
- [x] **Select all/deselect all** — QoL for multi-clip curation
- [x] **Empty state with parent video delete option** — Contextual cleanup

### Add After Validation (v1.x)

Features to add once core swipe workflow is validated by users.

- [ ] **Page-peel animation** — Trigger: Users request "more satisfying" swipe feel. Complexity: HIGH. Adds polish but not essential for v1.
- [ ] **Haptic feedback on actions** — Trigger: Users on iOS devices expect tactile feedback. Complexity: LOW. Easy win for perceived quality.
- [ ] **Swipe threshold customization** — Trigger: Users complain swipes are too sensitive/insensitive. Complexity: LOW. Hidden setting.
- [ ] **Export progress with cancel** — Trigger: Stitched export takes >10s, users get impatient. Complexity: MEDIUM. Not needed for single clips.

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] **Multi-clip comparison view** — Why defer: Complex UI (side-by-side?), unclear if users need it. Validate demand first.
- [ ] **Custom swipe actions** — Why defer: Power user feature. Most users won't configure. Keep simple for now.
- [ ] **Clip metadata overlay** — Why defer: Technical details clutter fast-review UI. Could add if coaches request timestamp/duration info.
- [ ] **Gesture tutorials/onboarding** — Why defer: Swipe is intuitive for most users. Add only if analytics show confusion.

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Swipe gestures | HIGH | MEDIUM | P1 |
| Tap action buttons | HIGH | LOW | P1 |
| Visual drag feedback | HIGH | MEDIUM | P1 |
| Spring physics | HIGH | MEDIUM | P1 |
| Video autoplay + loop | HIGH | MEDIUM | P1 |
| Orientation support | HIGH | HIGH | P1 |
| Single-level undo | HIGH | MEDIUM | P1 |
| Batch export | HIGH | MEDIUM | P1 |
| Select all/deselect all | MEDIUM | LOW | P1 |
| Empty state cleanup | MEDIUM | LOW | P1 |
| Page-peel animation | MEDIUM | HIGH | P2 |
| Haptic feedback | MEDIUM | LOW | P2 |
| Swipe threshold customization | LOW | LOW | P3 |
| Export progress/cancel | MEDIUM | MEDIUM | P2 |
| Clip metadata overlay | LOW | MEDIUM | P3 |
| Gesture onboarding | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch (table stakes + core differentiators)
- P2: Should have, add when possible (polish + validation-dependent)
- P3: Nice to have, future consideration (deferred until demand proven)

## Competitor Feature Analysis

| Feature | TikTok/Reels | Tinder | BumpSetCut Approach |
|---------|--------------|--------|---------------------|
| **Swipe direction** | Vertical (next video) | Horizontal (like/pass) | Horizontal (like/delete) — matches Tinder metaphor |
| **Undo** | None | 1 level (paid feature) | 1 level (free) — table stakes for curation |
| **Buttons as alternative** | None | Yes (heart, X buttons) | Yes (heart, trash) — accessibility + one-handed use |
| **Video behavior** | Autoplay, loop | N/A (static images) | Autoplay, loop — TikTok expectation |
| **Batch actions** | Save to collection | None | Export liked clips — differentiator for coaches |
| **Animation style** | Slide + fade | Card stack, tilt | Page-peel + stack — tactile metaphor |
| **Orientation handling** | Portrait only (forced) | Portrait only | Portrait + landscape — iOS user expectation |
| **Export/save** | Individual save | N/A | Individual or stitched — unique to video editing use case |
| **Delete action** | Remove from feed (soft) | Swipe left (temporary) | Swipe left (permanent) + undo — curation workflow |
| **Haptic feedback** | On actions (iOS 26+) | On swipes | On swipes + actions — iOS standard |

## Implementation Insights from Research

### Gesture Design (MEDIUM confidence — verified with iOS HIG, WebSearch)

- **Swipe threshold:** Modern card swipe libraries use 40-50% of card width as threshold. Lower = accidental triggers, higher = feels unresponsive.
- **Drag rotation:** Small rotation (5-15°) during drag reinforces direction. Too much (>20°) looks cartoony.
- **Velocity detection:** Fast swipe (high velocity) should complete action even if threshold not met. Feels more responsive.
- **Interruptible animations:** Spring animations must be interruptible. User should be able to start new swipe before previous animation finishes.

### Video Playback (HIGH confidence — iOS HIG, AVFoundation docs)

- **Autoplay requirements:** iOS requires `playsinline` attribute to prevent fullscreen takeover. Autoplay without sound allowed (user's own content).
- **Seamless loop:** Use AVPlayerLooper or monitor `didPlayToEndTime` notification. Restart must be <24ms for imperceptible gap.
- **Orientation transitions:** Preserve AVPlayer instance across orientation changes. Recreating player causes flicker/restart.
- **Preloading:** For card stack, preload next 1-2 videos in background. Instant playback when card revealed.

### Animation Performance (MEDIUM confidence — WebSearch, SwiftUI docs)

- **60fps target:** Swipe animations must maintain 60fps on iPhone 12+. Page-peel is GPU-intensive; may drop to 30fps on older devices.
- **Spring parameters:** Medium stiffness (300-400), medium damping (25-35) feels "natural" for card swipes per research. Too stiff = robotic, too loose = sluggish.
- **Staged springs:** Advanced technique: Use different spring parameters for drag vs. release. Drag = high stiffness (responsive), release = lower stiffness (settle naturally).

### Export Workflow (MEDIUM confidence — WebSearch)

- **Batch export UX:** Desktop video editors (CapCut, DemoCreator) have batch export. Mobile apps typically don't. Opportunity for differentiation.
- **Stitched vs individual:** Coaches likely want stitched (1 video for review session). Players want individual (share best rally). Support both.
- **Progress indication:** Export can take 5-30s for stitched videos. Show progress bar + cancel option. Users expect this from iOS Photos app.

## Sources

**High Confidence:**
- Apple Developer Documentation: Playing Video, Haptic Feedback, AVFoundation
- iOS 26 Human Interface Guidelines (via WebFetch, 2026)
- SwiftUI Spring Animation reference (GitHub: GetStream/swiftui-spring-animations)

**Medium Confidence:**
- TikTok/Instagram Reels UI patterns (WebSearch, 2026)
- Tinder swipe interaction patterns (WebSearch, community articles)
- Medium articles: "How Not to Design Swipe Actions" (2018, principles still relevant)
- ZURB: "5 Common Mistakes Designers Make When Using Cards" (WebFetch, 2026)

**Low Confidence (flagged for validation):**
- Specific swipe threshold percentages (40-50%) — based on library defaults, not user research
- Card rotation angle recommendations (5-15°) — design heuristic, not empirical data
- Preloading strategy (next 1-2 videos) — performance assumption, needs device testing

---
*Feature research for: Swipeable Card Video Viewer (BumpSetCut Rally Playback)*
*Researched: 2026-01-24*
