# Meta Horizon Store assets

This directory contains the branded store assets for the 00Widget Horizon OS
panel app. The committed PNGs under `assets/` are ready to upload; `build.py`
reproduces them from the approved brand masters and the art-directed atmosphere
plate under `sources/`.

## Upload map

| Developer Dashboard field | File |
| --- | --- |
| Universal basic asset | `assets/00widget-universal-basic-2560x1440.png` |
| Cover art — Landscape | `assets/00widget-cover-landscape-2560x1440.png` |
| Cover art — Square | `assets/00widget-cover-square-1440x1440.png` |
| Cover art — Portrait | `assets/00widget-cover-portrait-1008x1440.png` |
| Mini landscape | `assets/00widget-mini-landscape-1080x360.png` |
| Icon | `assets/00widget-icon-512x512.png` |
| Logo | `assets/00widget-logo-transparent-1254x1254.png` |
| Hero cover | `assets/00widget-hero-cover-3000x900.png` |
| Spatialized tile — Background | `assets/00widget-spatialized-background-180x180.png` |
| Spatialized tile — Foreground | `assets/00widget-spatialized-foreground-180x180.png` |

The Universal Basic Asset is the 16:9 source Meta can use to generate the cover
variants. Meta's September 2026 generator moved the title outside its own safe
area in landscape and portrait, so the format-specific files above are the
submission source of truth: replace the generated `uba_…` variants with them.
Every important element in those files is guarded against a conservative safe
area in `build.py`. The matching previews under `previews/` dim the bleed and
draw the enforced rectangle.

## Design contract

- Cover art contains only the exact `00Widget` title and representative,
  text-free panel imagery. It carries no tagline, feature copy, badge, price,
  quote, or platform reference.
- Universal and Hero covers use the same atmosphere, title artwork, dashboard
  language, and palette.
- Landscape, square, portrait, and mini-landscape covers are composed for
  their own aspect ratios. They are not mechanical crops of the Universal
  asset, because a single composition cannot keep the title and dashboard
  inside all four safe areas.
- The store icon is an opaque, square-cornered 24-bit PNG derived mechanically
  from `docs/brand/app-icon-master.png`.
- The logo preserves the approved U2 mark and its real transparent alpha.
- The optional spatialized tile uses an opaque atmosphere layer plus the exact
  mark on a separate transparent 180×180 foreground. The mark is wholly inside
  Meta's centered 138×138 safe area and carries no added hover shadow.
- The dashboard panels are cover-art illustrations, not screenshots. Do not
  reuse them as Store screenshots: Meta requires five unembellished images of
  actual in-experience content for that separate field.

## Rebuild

From the repository root:

```sh
python3.12 marketing/horizon-store/build.py
```

The script validates pixel dimensions, color mode, and logo alpha, then writes
`assets/manifest.json` with source and output checksums.

Meta's current specification source is the
[Horizon Store asset design guide](https://developers.meta.com/horizon/resources/asset-guidelines/).
