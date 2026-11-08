# PhotoFlow Design System

## 1. Product & visual concept

**Purpose.** PhotoFlow makes large photo collections look better with almost no effort: import, one-click enhance, straighten, find duplicates, export.
**Audience.** People with thousands of photos who are not photographers. They judge by looking, not by reading.
**Key workflows.** (1) Import → Auto Enhance → Export. (2) Find & clean up duplicates. (3) Batch-improve a whole folder. (4) Fine-tune one favourite photo.

**Concept: "Your photos are the interface."**
The app has no stock imagery and no decoration for its own sake. Colour and atmosphere come from the user's own photographs:
- **Ambient light.** Large surfaces (overview hero, editor canvas, inspector) are lit by a soft, heavily blurred glow sampled from the photo in focus – like light falling through coloured glass. It changes smoothly when the photo changes.
- **Glass with a job.** Glass is used for exactly three things: floating controls above content (toolbars, compare control), panels that sit *on* imagery (inspector, editor tools) and transient layers (toasts, sheets). Content itself (photos, grids, tables) is never put behind glass.
- **Show, don't tell.** Every state that used to be a sentence becomes a picture: histograms instead of numbers, before/after previews instead of feature descriptions, a storage bar instead of a byte count, illustrated empty states instead of instructions.

## 2. Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `brand` gradient | `#6C4CFF → #00B6FF` | same, +8 % luminance | primary actions, selection glow, progress |
| `magic` gradient | `#8A5CFF → #FF5FA2 → #FFB347` | same | Auto Enhance only (the "magic moment") |
| `canvas` | system window background + ambient glow | `#0E0F14` + ambient glow | window base |
| `ink.primary / secondary / tertiary` | system label colours | system label colours | text (never hard-coded black/white on surfaces) |
| `success` | `#2BB673` | `#34D399` | done, kept, recommended |
| `warning` | `#F59E0B` | `#FBBF24` | partial, needs review |
| `danger` | `#EF4444` | `#F87171` | delete, failed |
| similarity | red/orange/yellow/teal | brighter variants | exact / very / similar / possibly |

Accent colour follows the brand gradient; system accent is respected for focus rings and standard controls.

## 3. Typography (SF Pro, system dynamic sizes for macOS)

| Style | Font | Use |
|---|---|---|
| `display` | 40 pt, bold, rounded digits | overview hero, large statistics |
| `title1` | 26 pt, bold | screen titles |
| `title2` | 20 pt, semibold | section titles |
| `headline` | 13 pt, semibold | card titles, list emphasis |
| `body` | 13 pt, regular | text |
| `caption` | 11 pt, medium | metadata, chips |
| `numeric` | monospaced digits wherever numbers update | counters, progress |

Maximum two weights per view. Headlines are short; explanations live in tooltips and secondary text.

## 4. Spacing, radii, elevation

- **Spacing scale:** 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48. Screen margins 24, card padding 16, grid gutter 10.
- **Radii:** chip 8 · control 10 · card 16 · panel 20 · hero 28. Nested radii = outer − padding.
- **Elevation:** `rest` (no shadow, hairline) → `raised` (y 6, blur 18, 10 %/30 % dark) → `floating` (y 14, blur 36, 16 %/45 %). Glass highlights: 0.75 pt inner border, top-lit gradient.

## 5. Glass materials

| Level | macOS 26+ | macOS 13–15 fallback |
|---|---|---|
| L1 panel | `glassEffect(.regular)` | `.regularMaterial` + top-lit hairline + raised shadow |
| L2 floating control | `glassEffect(.regular.interactive())`, capsule | `.thinMaterial` capsule + hairline + floating shadow |
| L3 prominent action | `.glassProminent` button | brand-gradient capsule with inner highlight |
| Tinted glass | `glassEffect(.regular.tint(colour))` | material + 12 % colour overlay |

No fake "Liquid Glass" on older systems – the fallback is honest material design with the same shapes, spacing and hierarchy.

## 6. Motion

| Token | Curve | Use |
|---|---|---|
| `snappy` | spring 0.28 s, damping 0.86 | selection, hover, toggles |
| `smooth` | spring 0.45 s, damping 0.9 | screen and panel transitions, image cross-fades |
| `reveal` | ease-out 0.35 s + 30 ms stagger | grids and cards appearing |
| `celebrate` | spring 0.5 s, damping 0.7 (once) | finished batch, enhancement applied |

Rules: nothing longer than 0.5 s; no motion on scroll; motion always reflects a real state change; respects "Reduce Motion".

## 7. Components

`GlassPanel`, `FloatingBar`, `PrimaryButton` (brand/magic), `SoftButton`, `Chip`, `StatTile` (large number + mini-visual), `HistogramView`, `StorageBar`, `AmbientBackground` (photo glow), `PhotoMosaic`, `Illustration` (vector empty-state artwork drawn in SwiftUI – crisp at any size, adapts to light/dark), `ProgressRing`, `BeforeAfterCard`, `SectionHeader`, `EmptyState`.
