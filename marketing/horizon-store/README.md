# Meta Horizon Store assets

This directory contains the branded store assets for the 00Widget Horizon OS
panel app. The committed PNGs under `assets/` are ready to upload; `build.py`
reproduces them from the approved brand masters and the art-directed atmosphere
plate under `sources/`.

## Upload map

| Developer Dashboard field | File |
| --- | --- |
| Universal basic asset | `assets/00widget-universal-basic-2560x1440.png` |
| Icon | `assets/00widget-icon-512x512.png` |
| Logo | `assets/00widget-logo-transparent-1254x1254.png` |
| Hero cover | `assets/00widget-hero-cover-3000x900.png` |

The Universal Basic Asset is the 16:9 source Meta uses to generate the cover
landscape, square, portrait, and mini-landscape variants. Inspect every
generated crop in the Developer Dashboard before submitting. The centered
square and portrait images under `previews/` are deliberately conservative QA
crops, not additional upload assets.

## Design contract

- Cover art contains only the exact `00Widget` title and representative,
  text-free panel imagery. It carries no tagline, feature copy, badge, price,
  quote, or platform reference.
- Universal and Hero covers use the same atmosphere, title artwork, dashboard
  language, and palette.
- The store icon is an opaque, square-cornered 24-bit PNG derived mechanically
  from `docs/brand/app-icon-master.png`.
- The logo preserves the approved U2 mark and its real transparent alpha.
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
