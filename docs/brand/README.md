# 00Widget — Brand

The official brand assets and usage rules.

<p align="center">
  <img src="./wordmark-horizontal.png" alt="00Widget — Widgets for all your agents." width="720">
</p>

## Tagline

> Widgets for all your agents.

Use this exact wording — no rephrasing. It appears in:

- top-level `README.md`
- `ios/Resources/App/Info.plist` (CFBundleDisplayName tagline area)
- store listings, social cards

## Assets in this directory

| File                                  | Size       | Background       | Use                                                                                          |
| ------------------------------------- | ---------- | ---------------- | -------------------------------------------------------------------------------------------- |
| `mark-1024.png`                       | 1024×1024  | Opaque dark navy | iOS App Icon. Already wired into `ios/Resources/App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`. |
| `mark-transparent-1024.png`           | 1024×1024  | Transparent      | Mark on arbitrary backgrounds — buttons, badges, dark headers.                               |
| `wordmark-horizontal.png`             | 2400×813   | Opaque dark navy | Horizontal lockup with built-in dark-navy panel. README hero — works in light *and* dark themes. |
| `wordmark-horizontal-transparent.png` | 2400×711   | Transparent      | Horizontal lockup without panel. Use only when placing on a dark surface that gives enough contrast. |
| `branding-sheet.png`                  | 1536×1024  | —                | Reference contact sheet showing all variants together.                                       |

Vector sources (SVG) are not maintained for this revision; rasterize from a higher-res master if you need additional sizes.

## Color palette

Eyeballed from the rendered PNGs (treat as approximate — request authoritative hex values from the designer if you need them for new collateral).

| Role             | Approx hex            | Usage                                       |
| ---------------- | --------------------- | ------------------------------------------- |
| Brand blue       | `#1F8BFF` / `#0968E8` | "00" wordmark, primary accent               |
| Trend teal       | `#1FB89A`             | Trend-line accent inside the mark           |
| Accent purple    | `#5B35DB`             | Card row accent inside the mark             |
| Claw metal       | white → `#8291A6`     | Claw fill (gradient)                        |
| Deep navy        | `#06152A`             | Panel + card stroke + "Widget" text         |
| Mid navy         | `#243A57`             | Tagline                                     |
| Card surface     | `#F8FBFF`             | Card background inside the mark             |
| Card row gray    | `#D4DAE2`             | Inactive row in the mark                    |

## Usage rules

- **Do not** rephrase the tagline.
- **Do not** recolor the mark. Use the supplied variants as-is.
- **Do** keep clearspace around the mark equal to half the height of the "0" in `00Widget`.
- **Do not** stretch — preserve aspect ratio always.
- **Do not** place `mark-transparent-1024.png` on backgrounds that compete with the trend-teal or brand-blue accents (use near-black or near-white surfaces).
