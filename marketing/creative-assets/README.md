# App Store creative assets

This directory builds 00Widget's optional iOS 27 / iPadOS 27 creative assets:

| Placement | Upload file | Canvas | Apple art-safe area |
| --- | --- | ---: | ---: |
| Product page header | `00widget-product-page-header-3840x1646.png` | 3840×1646 | x 1097–2743, y 493–1154 |
| Search results | `00widget-search-results-3840x2560.png` | 3840×2560 | x 836–3004, y 765–1795 |

The dimensions and safe areas come from Apple's official Photoshop templates.
The output is intentionally not one universal crop. The header makes one
brand-led promise — U2 keeping a launch in sight — while Search pairs the exact
brand lockup with the real expanded Dynamic Island and Home Screen widgets so
the product's purpose is obvious at a smaller size.

The generated background plates in `sources/` provide atmosphere only; their
exact built-in ImageGen prompts are recorded in [`PROMPTS.md`](PROMPTS.md). Exact
identity and product content are composited by `build.py` from the approved U2
masters, the shipping App Clip activity render, and a real simulator capture.
Never ask image generation to redraw the mark, wordmark, product UI, or Apple
system surfaces.

Build both assets with:

```sh
python3.12 marketing/creative-assets/build.py
```

Upload-ready PNGs, safe-area review images, and a checksum manifest are written
to `artifacts/app-store/creative-assets/`. Review the two files in
`previews/` first: everything outside Apple's guaranteed rectangle is dimmed.

Before submission, use App Store Connect's product-page preview tool for both
iPhone and iPad crops. These assets are version-independent and may be
submitted with an app version or through the Asset Library. If another
localization is added, replace the English wordmark/tagline in the Search asset
with an approved localized lockup before assigning that localization.

Official guidance and templates:

- <https://developer.apple.com/app-store/asset-best-practices/>
- <https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-product_page_header_template-static.psd>
- <https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-search_results_template-static.psd>
