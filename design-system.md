# BumpSetCut Design System

**Source of truth.** Every design token lives in `BumpSetCut/DesignSystem/Tokens/DesignTokens.swift`; this document explains what each token means and the rules for using them. Change them together — a token added, removed, or re-valued in code must be reflected here, and vice versa.

```
BumpSetCut/DesignSystem/
├── Tokens/DesignTokens.swift   ← ALL tokens: colors, spacing, radius, shadows,
│                                 sizing, touch targets, animation, transitions
├── Typography/                 ← bscFont() Dynamic Type modifier + MFontModifier scale
└── Components/                 ← BSC* reusable components built on the tokens
```

## Principles

1. **Tokens, not literals.** Feature views never hardcode a color, spacing, radius, or duration. If no token fits, add one to `DesignTokens.swift` and document it here.
2. **Adaptive by default.** Surface and text colors carry light + dark values via `Color(light:dark:)`. A new color must define both or be deliberately mode-invariant (like the status hues and media surfaces).
3. **Media surfaces are dark by design.** Full-screen video contexts (feed, rally playback) always render dark chrome regardless of system appearance — use the `bscMedia*`/`bscOnMedia*` tokens there, never the adaptive text/surface tokens.
4. **Accessible by construction.** WCAG AA contrast, 44pt touch targets, Reduce Motion, and Dynamic Type are token/modifier concerns, handled once in the design system rather than per-view (details below).
5. **Themeable later.** Tokens are the future theming seam; the semantic layer (`bscPrimary`, `bscMediaScrim`, …) exists so a theme can restyle the app by redefining tokens, not by touching views.

## Color

### Brand

| Token | Value | Use |
|---|---|---|
| `bscBlue` / `bscPrimary` | `#3B82F6` | Primary brand. Fills, rings, tints, icons on dark |
| `bscBlueBright` / `bscPrimaryBright` | `#60A5FA` | Highlights on dark surfaces |
| `bscBlueDark` / `bscPrimaryDark` | `#2563EB` | Pressed states, gradient ends |
| `bscOrange` / `bscWarmAccent` | `#FF6B35` | Demoted warm accent — special callouts, favorites |
| `bscTeal` / accent | `#14B8A6` | Fresh/active accent, processing status |

### Surfaces (adaptive: light / dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `bscBackground` | `#F8F8FA` | `#0D0D0E` | Screen background |
| `bscBackgroundElevated` | `#FFFFFF` | `#1A1A1C` | Cards, pills, modals |
| `bscBackgroundMuted` | `#F0F0F3` | `#141416` | Subtle differentiation |
| `bscSurfaceGlass` | black 8% | white 5% | Frosted panels |
| `bscSurfaceBorder` | black 8% | white 8% | Hairline borders |
| `bscSurfaceHighlight` | black 6% | white 12% | Top-edge shine |

### Media overlay (mode-invariant — video is always a dark context)

| Token | Value | Use |
|---|---|---|
| `bscMediaBackground` | `#0D0D0E` | Full-bleed behind video players |
| `bscOnMedia` | white | Primary chrome over video |
| `bscOnMediaSecondary` | white 70% | Timestamps, inactive labels over video |
| `bscMediaScrim` | black 45% | Pill/badge/gradient scrims over bright frames |
| `bscMediaScrimBase` | black | Base for custom-opacity scrims (`.opacity(x)` on this, never on `Color.black`) |

### Text (adaptive: light / dark)

| Token | Light | Dark | AA on elevated bg (L/D) |
|---|---|---|---|
| `bscTextPrimary` | `#1A1A1C` | `#F1EFEF` | 17.4 / 15.2 ✅ |
| `bscTextSecondary` | `#6B6B76` | `#A1A1AA` | 5.3 / 6.8 ✅ |
| `bscTextTertiary` | `#9E9EA8` | `#71717A` | 2.7 / 3.6 ❌ — decorative hints only |
| `bscTextInverse` | `#F1EFEF` | `#0D0D0E` | for colored/inverted fills |

### Status + contrast-safe variants

Raw status hues are mode-invariant fills; **the `*Text` variants exist because the raw hues fail AA on light backgrounds** — use them for any text or meaningful glyph.

| Fill token | Value | Text/icon variant | Light / Dark | AA (L/D) |
|---|---|---|---|---|
| `bscSuccess` | `#22C55E` (2.3 on white ❌) | `bscSuccessText` | `#16A34A` / `#22C55E` | 3.3ᶦ / 7.6 ✅ |
| `bscError` | `#EF4444` (3.8 icon-only) | `bscErrorText` | `#DC2626` / `#EF4444` | 4.8 / 4.6 ✅ |
| `bscWarning` | `#F59E0B` (2.2 on white ❌) | `bscWarningText` | `#B45309` / `#F59E0B` | 5.0 / 8.1 ✅ |
| `bscInfo` / `bscPrimary` | `#3B82F6` (3.7 icon-only) | `bscPrimaryText` | `#2563EB` / `#60A5FA` | 5.2 / 6.8 ✅ |

ᶦ passes the 3:1 non-text bar; prefer it for icons, not body text, in light mode.
Each status hue also has a `*Subtle` 15%-opacity background variant.

### Rules

- **Text on light surfaces:** `bscTextPrimary`/`bscTextSecondary`, or a `*Text` status variant. Never raw `bscPrimary`/`bscSuccess`/`bscWarning` for text, and never `bscTextTertiary` for information the user needs.
- **Icons** need 3:1 (WCAG 1.4.11): raw `bscPrimary` and `bscError` pass; `bscSuccess` and `bscWarning` do not in light mode — use their `*Text` variants.
- **Over video:** only `bscOnMedia*` + scrim tokens; put a `bscMediaScrim` behind chrome that sits on unpredictable frames.

## Spacing, Radius, Sizing

| `BSCSpacing` | pt | | `BSCRadius` | pt | | `BSCIconSize` | pt |
|---|---|---|---|---|---|---|---|
| `xxs` | 2 | | `sm` | 6 | | `sm` | 16 |
| `xs` | 4 | | `md` | 10 | | `md` | 20 |
| `sm` | 8 | | `lg` | 14 | | `lg` | 24 |
| `md` | 12 | | `xl` | 20 | | `xl` | 32 |
| `lg` | 16 | | `xxl` | 28 | | `xxl` | 48 |
| `xl` | 24 | | `full` | 9999 | | | |
| `xxl` / `xxxl` / `huge` | 32 / 48 / 64 | | | | | | |

- 8pt grid; `xxs`/`xs` are for optical nudges only.
- `BSCContentWidth`: `compact` 320, `regular` 480, `wide` 720, `max` 1200 (pills/banners cap at 500 by convention).
- Convenience: `.bscCardPadding()` (= lg all around), `.bscSectionPadding()` (= lg horizontal, md vertical).

### Touch targets — `BSCTouchTarget`

| Token | pt | Use |
|---|---|---|
| `compact` | 32 | *Visual* size only — an interactive element this small must still get a 44pt hit area |
| `standard` | 44 | **Minimum hit area for anything tappable (Apple HIG)** |
| `large` / `extraLarge` | 60 / 70 | Prominent / primary actions |

**Rule:** grow the touchable area, not the visible icon: wrap the glyph with `.frame(width: 44, height: 44).contentShape(Rectangle())` inside the `Button` label (alignment keeps the glyph visually in place — see the low-storage banner dismiss in `MainTabView`, or the trim-handle hit padding in `RallyTrimOverlay`). Padding applied *outside* a `Button` is not tappable.

## Shadows — `BSCShadow`

`sm` (4/2, 15%) subtle · `md` (8/4, 20%) cards, pills · `lg` (16/8, 25%) modals · `xl` (24/12, 30%) floating. Glows: `glowPrimary`, `glowBlue`, `glowSuccess`, `glowError` (0-offset, 40% tint). Apply with `.bscShadow(BSCShadow.md)`.

## Typography

- **`.bscFont(size:weight:design:)`** is the standard text modifier — a drop-in for `.font(.system(...))` that scales with Dynamic Type and live-updates when the user changes text size (`Typography/BSCScaledFont.swift`). Never use fixed `Font.system(size:)` directly.
- **`MFontModifier`** provides the named scale (display1/2, h1–h6, body, labels, captions, plus semantic aliases like `cardTitle`, `statValue`) with tuned line heights and kerning.
- Common ad-hoc sizes in chrome: 13 semibold (pill titles), 11 (pill subtitles), 14 bold monospaced (percentages), 12 medium (banners).

## Animation

- Curves: `bscQuick` 0.15s · `bscStandard` 0.25s · `bscEmphasized` 0.35s. Springs: `bscSpring` (default, soft) · `bscBounce` (energetic) · `bscSnappy` · `bscSwipe`. Ambient: `bscFloat` / `bscPulse` / `bscSpin`.
- Transitions: `bscSlideUp/Down`, `bscScale(Up)`, `bscFade`, `bscBlur`. Durations for manual timing in `BSCDuration`.
- Effect modifiers `.bscFloatingEffect()`, `.bscPulseGlow()`, `.bscStaggered(index:)`, `.bscShimmer()` **honor Reduce Motion and stop off-screen** — use them instead of hand-rolled `repeatForever` animations.
- `BSCCardTransition` holds the card-stack math (rotation/scale/opacity/offset).

## Accessibility standard (enforced, not aspirational)

1. **Contrast:** WCAG AA — 4.5:1 for text, 3:1 for icons/meaningful non-text. The token tables above encode which combinations pass; the pill layer in `MainTabView` was audited element-by-element (2026-09-08) and passes in both modes.
2. **Touch targets:** 44×44pt minimum hit area for every interactive element.
3. **Reduce Motion:** ambient/decorative animation must check `accessibilityReduceMotion` (the token modifiers already do).
4. **Dynamic Type:** all text through `.bscFont(...)` or `MFontModifier`.
5. **VoiceOver:** icon-only buttons get `.accessibilityLabel`; custom adjustable controls implement `accessibilityAdjustableAction` (see `RallyTrimOverlay` trim handles).

## Components (built on the tokens)

`BSCButton`, `BSCIconButton` (circular, sized via `BSCTouchTarget`), `BSCCard`/`BSCFolderCard`/`BSCVideoCard`, `BSCToast`, `BSCEmptyState`, `BSCErrorState`, `BSCLoadingOverlay`, `BSCProgressView`, `BSCSkeletonView`, `BSCSearchBar`, `BSCBreadcrumb`, `LoadingStatusBar`, `AvatarView`, `VideoThumbnailView`, `MetadataOverlayView`. Prefer these over bespoke views; extend them rather than forking their styling.

## Changing tokens

1. Edit `DesignTokens.swift` (both modes for adaptive colors; verify contrast for anything that renders text — quick check: relative-luminance ratio ≥ 4.5 text / ≥ 3.0 icons).
2. Update the matching table here.
3. `scripts/build.sh ios` (DesignSystem is iOS-only; RallyLab is unaffected).
