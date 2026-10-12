#!/usr/bin/env python3
"""Build the iOS 27 App Store creative assets for 00Widget.

The background plates are art-directed raster sources. Every element that has
to be exact — the U2 mark, wordmark, tagline, and product UI — comes from the
approved brand masters or a real product render/capture in this repository.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = Path(__file__).resolve().parent / "sources"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "artifacts" / "app-store" / "creative-assets"

MARK = REPO_ROOT / "docs" / "brand" / "mark-transparent-master.png"
WORDMARK = REPO_ROOT / "docs" / "brand" / "wordmark-horizontal-transparent.png"
ACTIVITY = REPO_ROOT / "docs" / "brand" / "sources" / "app-clip-activity.png"
ISLAND_CAPTURE = (
    REPO_ROOT
    / "artifacts"
    / "screenshots"
    / "raw"
    / "iphone-6.3"
    / "screenshot-island-expanded.png"
)

BRAND_BLUE = (31, 139, 255, 255)
TREND_TEAL = (31, 184, 154, 255)
DEEP_NAVY = (6, 21, 42, 255)


@dataclass(frozen=True)
class AssetSpec:
    name: str
    size: tuple[int, int]
    safe_area: tuple[int, int, int, int]
    background: Path


# The outer green rectangles in Apple's September 2026 Photoshop templates.
# Coordinates use Pillow's exclusive right/bottom convention.
HEADER = AssetSpec(
    name="00widget-product-page-header-3840x1646.png",
    size=(3840, 1646),
    safe_area=(1097, 493, 2743, 1154),
    background=SOURCE_DIR / "product-page-header-background.png",
)
SEARCH = AssetSpec(
    name="00widget-search-results-3840x2560.png",
    size=(3840, 2560),
    safe_area=(836, 765, 3004, 1795),
    background=SOURCE_DIR / "search-results-background.png",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_sources() -> None:
    missing = [
        path
        for path in (HEADER.background, SEARCH.background, MARK, WORDMARK, ACTIVITY, ISLAND_CAPTURE)
        if not path.exists()
    ]
    if missing:
        raise SystemExit("Missing creative-asset source(s):\n" + "\n".join(map(str, missing)))


def trim_alpha(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    box = rgba.getbbox()
    return rgba.crop(box) if box else rgba


def contain(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.contain(image.convert("RGBA"), size, Image.Resampling.LANCZOS)


def rounded(image: Image.Image, radius: int) -> Image.Image:
    rgba = image.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, rgba.width - 1, rgba.height - 1),
        radius=radius,
        fill=255,
    )
    rgba.putalpha(ImageChops.multiply(rgba.getchannel("A"), mask))
    return rgba


def add_outline(image: Image.Image, width: int, color: tuple[int, int, int, int]) -> Image.Image:
    """Add a quiet outside stroke without changing the source UI itself."""
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    expanded = alpha.filter(ImageFilter.MaxFilter(width * 2 + 1))
    outline = ImageChops.subtract(expanded, alpha)
    layer = Image.new("RGBA", rgba.size, color)
    layer.putalpha(ImageChops.multiply(outline, Image.new("L", rgba.size, color[3])))
    layer.alpha_composite(rgba)
    return layer


def composite_with_shadow(
    canvas: Image.Image,
    image: Image.Image,
    xy: tuple[int, int],
    *,
    blur: int,
    opacity: int,
    offset: tuple[int, int] = (0, 16),
) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = image.getchannel("A")
    shadow_shape = Image.new("RGBA", image.size, (0, 0, 0, opacity))
    shadow_shape.putalpha(ImageChops.multiply(alpha, Image.new("L", image.size, opacity)))
    shadow.alpha_composite(shadow_shape, (xy[0] + offset[0], xy[1] + offset[1]))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(image, xy)


def inside(box: tuple[int, int, int, int], safe: tuple[int, int, int, int]) -> None:
    if not (
        box[0] >= safe[0]
        and box[1] >= safe[1]
        and box[2] <= safe[2]
        and box[3] <= safe[3]
    ):
        raise AssertionError(f"Essential art {box} falls outside Apple's safe area {safe}")


def background(spec: AssetSpec) -> Image.Image:
    source = Image.open(spec.background).convert("RGB")
    return ImageOps.fit(source, spec.size, method=Image.Resampling.LANCZOS).convert("RGBA")


def build_header() -> Image.Image:
    canvas = background(HEADER)

    mark = contain(trim_alpha(Image.open(MARK)), (430, 540))
    mark_xy = (1125, 553)
    inside((mark_xy[0], mark_xy[1], mark_xy[0] + mark.width, mark_xy[1] + mark.height), HEADER.safe_area)
    composite_with_shadow(canvas, mark, mark_xy, blur=28, opacity=120, offset=(0, 20))

    activity = contain(trim_alpha(Image.open(ACTIVITY)), (1110, 628))
    activity = add_outline(activity, 3, (248, 251, 255, 70))
    activity_xy = (1585, 510)
    inside(
        (
            activity_xy[0],
            activity_xy[1],
            activity_xy[0] + activity.width,
            activity_xy[1] + activity.height,
        ),
        HEADER.safe_area,
    )
    composite_with_shadow(canvas, activity, activity_xy, blur=38, opacity=155, offset=(0, 24))
    return canvas.convert("RGB")


def build_search() -> Image.Image:
    canvas = background(SEARCH)
    canvas_bounds = (0, 0, *SEARCH.size)

    mark = contain(trim_alpha(Image.open(MARK)), (440, 440))
    mark_xy = (900, 210)
    inside((mark_xy[0], mark_xy[1], mark_xy[0] + mark.width, mark_xy[1] + mark.height), canvas_bounds)
    composite_with_shadow(canvas, mark, mark_xy, blur=28, opacity=125, offset=(0, 18))

    wordmark = contain(trim_alpha(Image.open(WORDMARK)), (1600, 500))
    wordmark_xy = (1390, 285)
    inside(
        (
            wordmark_xy[0],
            wordmark_xy[1],
            wordmark_xy[0] + wordmark.width,
            wordmark_xy[1] + wordmark.height,
        ),
        canvas_bounds,
    )
    composite_with_shadow(canvas, wordmark, wordmark_xy, blur=18, opacity=90, offset=(0, 10))

    # Only the focal activity needs to survive the smallest Apple crop. Keeping
    # the entire composition in that rectangle made Search mostly background.
    # Branding and complete supporting widgets use the rest of the 3:2 canvas.
    capture = Image.open(ISLAND_CAPTURE).convert("RGBA")
    if capture.size != (1206, 2622):
        raise AssertionError(f"Search cutouts require the 6.3-inch capture, got {capture.size}")

    # Extract the actual system silhouette, including its continuous corners.
    # A circular mask leaves slivers of the wallpaper around this black pill.
    activity = capture.crop((36, 36, 1170, 394))
    mask = Image.new("L", activity.size, 0)
    draw = ImageDraw.Draw(mask)
    pixels = activity.load()
    for y in range(activity.height):
        dark = [x for x in range(activity.width) if max(pixels[x, y][:3]) < 12]
        if dark:
            draw.line((dark[0], y, dark[-1], y), fill=255)
    activity.putalpha(mask)
    activity = contain(trim_alpha(activity), (2100, 700))
    activity_xy = (870, 800)
    inside(
        (
            activity_xy[0],
            activity_xy[1],
            activity_xy[0] + activity.width,
            activity_xy[1] + activity.height,
        ),
        SEARCH.safe_area,
    )
    composite_with_shadow(canvas, activity, activity_xy, blur=42, opacity=170, offset=(0, 28))

    # The expanded Island obscures the first row. Use the two intact widgets
    # below it, removing only their surrounding wallpaper and app-name labels.
    for box, xy in (
        ((80, 873, 572, 1365), (720, 1480)),
        ((635, 873, 1127, 1365), (2050, 1480)),
    ):
        widget = contain(rounded(capture.crop(box), radius=112), (1000, 1000))
        inside((xy[0], xy[1], xy[0] + widget.width, xy[1] + widget.height), canvas_bounds)
        composite_with_shadow(canvas, widget, xy, blur=42, opacity=170, offset=(0, 28))
    return canvas.convert("RGB")


def safe_area_preview(image: Image.Image, spec: AssetSpec) -> Image.Image:
    """Dim the bleed and outline Apple's guaranteed art-safe rectangle."""
    preview = image.convert("RGBA")
    dim = Image.new("RGBA", image.size, (0, 0, 0, 145))
    clear = Image.new("L", image.size, 255)
    ImageDraw.Draw(clear).rectangle(spec.safe_area, fill=0)
    dim.putalpha(clear.point(lambda value: round(value * 145 / 255)))
    preview.alpha_composite(dim)
    draw = ImageDraw.Draw(preview)
    draw.rectangle(spec.safe_area, outline=TREND_TEAL, width=8)
    return preview.convert("RGB")


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def main() -> None:
    require_sources()
    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    built = ((HEADER, build_header()), (SEARCH, build_search()))
    records: list[dict[str, object]] = []
    for spec, image in built:
        if image.size != spec.size or image.mode != "RGB":
            raise AssertionError(f"Invalid output for {spec.name}: {image.size} {image.mode}")
        output = DEFAULT_OUTPUT_DIR / spec.name
        preview = DEFAULT_OUTPUT_DIR / "previews" / spec.name
        save(image, output)
        save(safe_area_preview(image, spec), preview)
        if spec == SEARCH:
            # Match the placement in the storefront reference, not a zoomed
            # desktop review that hides unreadable text and wasted space.
            save(
                image.resize((526, 351), Image.Resampling.LANCZOS),
                DEFAULT_OUTPUT_DIR / "previews" / "search-card-526x351.png",
            )
            save(
                image.crop(spec.safe_area),
                DEFAULT_OUTPUT_DIR / "previews" / "search-focal-crop.png",
            )
        records.append(
            {
                "filename": spec.name,
                "dimensions": list(spec.size),
                "safeArea": list(spec.safe_area),
                "outputSha256": sha256(output),
                "backgroundSha256": sha256(spec.background),
            }
        )

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sources": {
            str(MARK.relative_to(REPO_ROOT)): sha256(MARK),
            str(WORDMARK.relative_to(REPO_ROOT)): sha256(WORDMARK),
            str(ACTIVITY.relative_to(REPO_ROOT)): sha256(ACTIVITY),
            str(ISLAND_CAPTURE.relative_to(REPO_ROOT)): sha256(ISLAND_CAPTURE),
        },
        "assets": records,
    }
    (DEFAULT_OUTPUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for spec, _ in built:
        print(DEFAULT_OUTPUT_DIR / spec.name)
    print(DEFAULT_OUTPUT_DIR / "manifest.json")


if __name__ == "__main__":
    main()
