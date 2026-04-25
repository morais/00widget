# 00Widget — Brand

The official brand assets and usage rules.

<p align="center">
  <img src="./wordmark-horizontal.png" alt="00Widget — Widgets for all your agents." width="640">
</p>

## Tagline

> Widgets for all your agents.

Use this exact wording — no rephrasing. It appears in:

- top-level `README.md`
- `ios/Resources/App/Info.plist` (CFBundleDisplayName tagline area)
- store listings, social cards

## Assets in this directory

| File                            | Size       | Background  | Use                                   |
| ------------------------------- | ---------- | ----------- | ------------------------------------- |
| `mark-1024.png`                 | 1024×1024  | Opaque      | iOS App Icon (no transparency allowed). Already wired into `ios/Resources/App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`. |
| `mark-transparent-1024.png`     | 1024×1024  | Transparent | Mark on arbitrary backgrounds — buttons, badges, dark headers. |
| `wordmark-horizontal.png`       | 2400×800   | Transparent | Horizontal lockup of icon + "00Widget" + tagline. README hero, social cards, navigation lockups. |
| `mark.svg` / `mark-transparent.svg` | vector | —           | Source of truth for the icon. Re-export raster sizes from these. |
| `wordmark.svg` / `wordmark-horizontal.svg` | vector | —    | Source of truth for the lockup. |
| `branding-sheet.png`            | 1536×1024  | —           | Reference contact sheet showing all variants together. |

## Color palette

Sourced from the SVG `<linearGradient>` definitions — these are the authoritative values, not eyeballed samples.

| Role               | Stops                              | Usage                                   |
| ------------------ | ---------------------------------- | --------------------------------------- |
| Brand blue         | `#22A8FF` → `#0968E8`              | "00" wordmark, primary CTAs, card row   |
| Trend teal         | `#24D6B5` → `#11A789`              | Trend-line accent inside the mark       |
| Accent purple      | `#8B5CF6` → `#5B35DB`              | Card row accent inside the mark         |
| Claw metal         | `#FFFFFF` → `#D8DEE8` → `#8291A6`  | Claw fill                               |
| Deep navy          | `#06152A`                          | "Widget" wordmark, card stroke, dark text |
| Mid navy           | `#243A57`                          | Tagline, secondary text                 |
| Outline navy       | `#0C2340` (heavy) / `#304765` (highlight) | Claw outline, hierarchy lines    |
| Card surface       | `#F8FBFF`                          | Card background inside the mark         |
| Card row gray      | `#D4DAE2`                          | Inactive row in the mark                |

## Usage rules

- **Do not** rephrase the tagline.
- **Do not** recolor the mark. Use the supplied light/dark/mono variants as-is. If you need a new variant, re-export from the SVG sources.
- **Do** keep clearspace around the mark equal to half the height of the "0" in `00Widget`.
- **Do not** stretch — preserve aspect ratio always.
- **Do not** use the transparent mark on a background that competes with the trend-teal or brand-blue accents (use a near-black or near-white surface).
