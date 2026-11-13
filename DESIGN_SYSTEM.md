# PhotoFlow 2.0 – Design System

Source of truth for every screen. Implemented in `Sources/PhotoFlow/UI/Design/`:
`DesignTokens.swift` (colours, type, spacing, radii, ambient light, histogram, progress ring),
`Glass.swift` (the four material levels, buttons), `Motion.swift` (motion system, tooltips, focus depth),
`Components.swift` (controls), `Illustrations.swift`, `SamplePhotos.swift` (built-in sample scenes, compare slider).
No screen uses ad-hoc colours, radii or animations.

## 1. Idea

**"Your photos are the interface."** PhotoFlow is a photo application; photographs are the stars.
The interface is a calm, warm-grey (light) or anthracite (dark) room of glass in which the photos are lit,
and the light of the selected photo tints the room very softly.

The visual identity comes from the **app icon** (binding, used unchanged): a lavender-white glass squircle,
a photo with sky-blue mountains, a warm sun and three slider knobs. From it we take
- the **accent colours** (sky blue, light sky/cyan, periwinkle/iris, sun),
- the **materials** (frosted, slightly lavender glass with a bright rim),
- the **shapes** (continuous corners, soft depth, round knobs).

Layout and structure are inspired by modern Apple media apps (large titles, floating glass controls,
month-grouped grids, a floating "now playing"-style bar) – colours are **not** taken from any reference.

Principles: clean · premium · photographic · dynamic · spatial · fluid · consistent.
Never: neon colours, arbitrary gradients, large empty colour fields, generic dashboard cards,
glass for its own sake, effects without a purpose.

## 2. Colour

All colours are appearance-aware (`Color.dynamic(light:dark:)`).

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F4F3F1` warm very light grey | `#1B1C20` deep anthracite | window base |
| `canvasDeep` | `#ECEAE7` | `#151619` | sidebar tint |
| `surface` / `surfaceStrong` | white 72 % / 94 % | `#2A2B31` 62 % / `#303138` 92 % | cards, selection pill |
| `glassTint` | white 38 % | `#26272D` 42 % | tint inside glass |
| `stage` | `#E9E8E6` | `#121316` | behind photos (viewer, editor, compare) |
| `hairline` / `track` / `rim` | black 7 % / 12 % / white 85 % | white 8 % / 16 % / 16 % | separators, slider tracks, glass rim light |
| `textPrimary / Secondary / Tertiary` | `#1C1D22 / #5E606A / #8E9099` | `#F2F2F5 / #A9ABB5 / #75777F` | typography |
| `blue` (primary) | `#2F7BF5` | `#4A93FF` | primary actions, selection, focus – the mountains |
| `sky` | `#1FA2EE` | `#5CC2FF` | secondary accent, glows – the sky |
| `iris` | `#6E5CF0` | `#8C7DFF` | violet accent – the periwinkle glow |
| `sun` / `peach` | `#FDB54E` / `#FD9F7A` | same | premium highlights only (rim of the premium button, warnings in progress) |
| `heart` | `#F2456A` | `#FF6B86` | favourites |
| `success / warning / danger` | `#23A866 / #E08A12 / #E5484D` | `#3DD68C / #F5B342 / #FF6369` | semantic states |
| `hover` | black 4.5 % | white 6 % | hover fills |
| `focus` | blue 55 % | blue 55 % | focus rings |
| `disabled` | tertiary text 55 % | same | disabled content (plus 42 % opacity on controls) |

Gradients: `brand` (blue → iris) for primary actions and selection; `magic` (sky → blue → iris) for
Auto-Enhance glyphs; `premium` (#3D8DFB → #6C63F2 → #8E78F5) for the premium material; `sunrise` (sun → peach) sparingly.

## 3. Materials (four levels)

| Level | Used for | macOS 26+ | macOS 13–15 fallback |
|---|---|---|---|
| **1 · Background Glass** | sidebar, large regions | `NSVisualEffectView` `.sidebar`, behind-window | same + warm `canvasDeep` tint, hairline edge |
| **2 · Floating Glass** | top-bar controls, filter capsule, inspector, selection bar, popover-like panels, toasts | Liquid Glass `glassEffect(.regular)` | ultra-thin material + `glassTint` + top-down light refraction + rim light (white → transparent) + soft two-layer shadow |
| **3 · Interactive Glass** | secondary buttons, search field, segmented controls, text fields | Liquid Glass `.regular.interactive()` | thin material, inner highlight, hover brightening, press scale |
| **4 · Premium Glass** | Auto Enhance, Export, Start Processing, progress moments | brand/premium gradient, sheen, sun-tinted rim, coloured glow | identical (custom drawn) |

Rules: content (photos, grids, tables) is never behind glass. Glass sits *above* content.
Only one premium element per screen region. The Liquid Glass look does not depend on macOS 26 –
the fallback reproduces rim light, refraction gradient and depth.

## 4. Typography (SF Pro – system font)

| Token | Size / weight | Use |
|---|---|---|
| `display` | 34 bold | welcome title |
| `largeTitle` | 30 bold | page titles (Overview, All Photos …) |
| `title1` | 22 bold | hero captions, dialog titles, empty states |
| `title2` | 17 semibold | panel titles |
| `title3` | 15 semibold | group headers (month sections, import sessions) |
| `headline` | 13 semibold | card titles, list emphasis |
| `body` | 13 regular | default |
| `callout` | 12 regular | secondary lines, slider labels |
| `caption` | 11 medium | metadata, chips |
| `micro` / `sectionLabel` | 10–11 semibold, tracked, uppercase | control-group labels |
| `statNumber` | 26 semibold rounded, monospaced digits | statistics, progress |
| `number` | 13 medium, monospaced digits | slider values |

Numbers use monospaced digits and animate with `.numericText()` on macOS 14+.

## 5. Spacing, radii, depth

Spacing scale 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48; page margin 28; top bar 52.
Radius scale (continuous corners only): xs 6 · chip 8 · control 10 · tile 12 (photos) · card 18 · panel 22 · hero 28.
Depth: floating surfaces have a large soft shadow (22 pt, 10 pt offset; 10 % light / 42 % dark) plus a 1 pt contact shadow.
Selected items gain a blue glow instead of a heavier shadow.

## 6. Motion system

| Token | Spring / curve | Use |
|---|---|---|
| `hover` | spring 0.22 / 0.80 | hover reactions, presses |
| `snappy` | spring 0.28 / 0.86 | selection, toggles, segmented indicator |
| `smooth` | spring 0.45 / 0.90 | panels, inspector, viewer browsing |
| `page` | spring 0.50 / 0.88 | page changes (opacity + 10 pt rise + 0.99 scale) |
| `gentle` | spring 0.60 / 0.92 | large layout changes |
| `celebrate` | spring 0.50 / 0.70 | success moments (checkmark, ring pulse, heart) |
| `ambient` | ease-in-out 0.9 s | ambient light cross-fade |
| `quick` | ease-out 0.15 s | tooltips, small fades |

**Reduce Motion** (`DS.Motion.adaptive`) replaces movement by 0.12 s cross-fades and disables loops,
magnetic hover, zoom and stagger. Looping animations are always *scoped* to their own view
(`loopAnimation`), never started with `withAnimation` in `onAppear`.

### The 15 effects – where they live
1. **Dynamic Ambient Light** – `AmbientBackground`: 2–3 dominant colours per photo (hue histogram on a 48 px thumbnail, softened, cached in `DominantColorCache`), drawn as cheap radial light fields; window-wide; cross-fades.
2. **Liquid Glass Reflections** – sheen sweep on primary/premium buttons and photo tiles on hover only (`glassReflection`).
3. **Magnetic Hover** – `magneticHover`: ≤ 2.5 % scale, ≤ 3 pt lift, soft shadow.
4. **Morphing Transitions** – thumbnail → viewer zoom from the tile's real frame and back; sidebar pill and segmented indicators via `matchedGeometryEffect`; workflow card → live preview.
5. **Animated Selection** – checkmark scales in, ring + inner white rim, tile settles to 96.5 %; sidebar pill glides.
6. **Premium Progress Ring** – angular gradient, glowing leading tip, pulse at 100 %.
7. **Photo Reveal** – newly imported photos scale-and-fade in, staggered over the first 14 only.
8. **Before/After Reveal** – `BeforeAfterSlider` / `SplitCompare` with glowing divider and handle.
9. **Animated Histogram** – real RGB + luminance data; `HistogramShape` is animatable and morphs.
10. **Contextual Tooltips** – `tip(_:shortcut:)`: 0.6 s delay, glass capsule, key caps.
11. **Focus Depth** – window content recedes (scale 0.985, slight desaturation, 1.5 pt blur) behind sheets and the viewer.
12. **Smart Loading** – `ShimmerBlock` only while a thumbnail/histogram is actually loading.
13. **Success Feedback** – toast with popping symbol; heart bounce; "Saved" confirmation in the editor.
14. **Intelligent Background Blur** – viewer veil + focus depth; context-dependent strength.
15. **Smooth Scrolling** – lazy stacks, stable IDs, scroll position restored when returning from viewer/editor, top-fade mask under the floating bar.

## 7. Components

`PageHeader`, `GroupHeader`, `ControlLabel`, `EmptyStateView`, `StatTile`, `Badge`,
`FluidSlider` (fill from the neutral point, growing thumb, VoiceOver adjustable), `AdjustmentSlider`,
`GlassSwitchStyle` (`.glassSwitch`), `GlassSegmented` (gliding indicator), `GlassSearchField`,
`GlassButtonStyle` (primary · premium · secondary · destructive · plain), `GlassIconButtonStyle`,
`ToastView`, `ProgressRing`, `HistogramPlot`, `SegmentBar`, `BrandMark`, `Illustration`, `SamplePhoto`,
`BeforeAfterSlider`, `CompareDivider`, `OptionChip`, `GlassMenuRow`, `SelectionBar`, `TopBar`.

## 8. Window structure

```
┌ Background Glass sidebar (236) ┬ stage ──────────────────────────────────────────┐
│ ● ● ●                 ⎕       │  [⎕]                    [activity] [◨] [+ Import] │ ← floating top bar (drag area)
│ ◉ PhotoFlow                    │  Large Title                                      │
│ Library                        │  count line                                        │
│  ▸ Overview  (glass pill)      │  [search……………]          (mosaic|grid|list ↕ ⌯ ━○━) │ ← floating control capsule
│ Albums / Tools                 │  Month section ───────────────────────────────    │
│                                │  photo mosaic …                       ┌Inspector┐ │ ← floating glass panel
│ 🔒 100 % on-device             │        ( selection bar – floating glass )│        │ │
└────────────────────────────────┴──────────────────────────────────────────────────┘
```

## 9. Accessibility

Reduce Motion respected everywhere; text contrast ≥ 4.5 : 1 for body text in both appearances;
all custom controls expose labels, values and adjustable actions to VoiceOver; keyboard: Space opens/closes
the viewer, ←/→ browse, Esc closes, ⌘↩ edit, ⌘E enhance, ⌃⌘S sidebar, ⌥⌘I inspector; focus ring on the search field.
