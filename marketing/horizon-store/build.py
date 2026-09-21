#!/usr/bin/env python3
"""Build the branded Meta Horizon Store assets for 00Widget.

The atmosphere plate is an art-directed raster source. Every element that has
to be exact comes from the approved brand masters; the dashboard panels are a
deliberately text-free cover-art illustration, not a claimed app screenshot.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE_DIR = HERE / "sources"
OUTPUT_DIR = HERE / "assets"
PREVIEW_DIR = HERE / "previews"

BACKGROUND = SOURCE_DIR / "cover-background.png"
APP_ICON = REPO_ROOT / "docs" / "brand" / "app-icon-master.png"
MARK = REPO_ROOT / "docs" / "brand" / "mark-transparent-master.png"
WORDMARK = REPO_ROOT / "docs" / "brand" / "wordmark-horizontal-transparent.png"

UNIVERSAL_NAME = "00widget-universal-basic-2560x1440.png"
HERO_NAME = "00widget-hero-cover-3000x900.png"
ICON_NAME = "00widget-icon-512x512.png"
LOGO_NAME = "00widget-logo-transparent-1254x1254.png"
SPATIAL_BACKGROUND_NAME = "00widget-spatialized-background-180x180.png"
SPATIAL_FOREGROUND_NAME = "00widget-spatialized-foreground-180x180.png"

# Conservative inset of the blue safe rectangle shown by Meta's Developer
# Dashboard for the 3000x900 Hero Cover. The title is the essential element
# this build pins to it; decorative panels may continue into the bleed.
HERO_SAFE_AREA = (560, 120, 2440, 720)
SPATIAL_FOREGROUND_SAFE_AREA = (21, 21, 159, 159)

DEEP_NAVY = (6, 21, 42, 255)
PANEL = (8, 14, 27, 232)
CARD = (25, 31, 44, 235)
CARD_SOFT = (35, 43, 58, 220)
WHITE = (248, 251, 255, 255)
MUTED = (137, 153, 178, 255)
BLUE = (31, 139, 255, 255)
TEAL = (31, 184, 154, 255)
PURPLE = (91, 53, 219, 255)
GREEN = (48, 209, 88, 255)
ORANGE = (255, 149, 0, 255)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def trim_alpha(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    box = rgba.getbbox()
    return rgba.crop(box) if box else rgba


def contain(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.contain(image.convert("RGBA"), size, Image.Resampling.LANCZOS)


def cover_background(size: tuple[int, int]) -> Image.Image:
    source = Image.open(BACKGROUND).convert("RGB")
    return ImageOps.fit(source, size, method=Image.Resampling.LANCZOS).convert("RGBA")


def title_art(max_size: tuple[int, int]) -> Image.Image:
    """Return the exact approved 00Widget title, excluding the tagline."""
    source = Image.open(WORDMARK).convert("RGBA")
    # The master has a transparent row gap between the approved title and
    # tagline. Crop only at that gap; never recreate the typography.
    title = trim_alpha(source.crop((0, 0, source.width, 520)))
    return contain(title, max_size)


def inside(box: tuple[int, int, int, int], safe: tuple[int, int, int, int]) -> None:
    if not (
        box[0] >= safe[0]
        and box[1] >= safe[1]
        and box[2] <= safe[2]
        and box[3] <= safe[3]
    ):
        raise AssertionError(f"Essential art {box} falls outside safe area {safe}")


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255
    )
    return mask


def glass_panel(size: tuple[int, int]) -> Image.Image:
    """Illustrate the app's panel vocabulary without pretending to screenshot it."""
    width, height = size
    panel = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(panel)
    draw.rounded_rectangle(
        (2, 2, width - 3, height - 3),
        radius=52,
        fill=PANEL,
        outline=(203, 220, 255, 92),
        width=3,
    )

    pad = 48
    header_h = 78
    mark = contain(trim_alpha(Image.open(MARK)), (70, 70))
    panel.alpha_composite(mark, (pad, 22))
    for index, color in enumerate((BLUE, TEAL, PURPLE)):
        x = width - pad - 112 + index * 38
        draw.ellipse((x, 42, x + 17, 59), fill=color)

    gap = 24
    card_y = pad + header_h
    card_w = (width - pad * 2 - gap) // 2
    card_h = (height - card_y - pad - gap) // 2
    boxes = [
        (pad, card_y, pad + card_w, card_y + card_h),
        (pad + card_w + gap, card_y, width - pad, card_y + card_h),
        (pad, card_y + card_h + gap, pad + card_w, height - pad),
        (pad + card_w + gap, card_y + card_h + gap, width - pad, height - pad),
    ]
    for box in boxes:
        draw.rounded_rectangle(box, radius=30, fill=CARD, outline=(255, 255, 255, 28), width=2)

    # Progress card: a strong value shape and a nearly complete progress run.
    x1, y1, x2, y2 = boxes[0]
    draw.ellipse((x1 + 28, y1 + 28, x1 + 50, y1 + 50), fill=ORANGE)
    draw.rounded_rectangle((x1 + 72, y1 + 28, x2 - 34, y1 + 44), radius=8, fill=MUTED)
    draw.rounded_rectangle((x1 + 28, y1 + 74, x1 + 154, y1 + 104), radius=15, fill=WHITE)
    track = (x1 + 28, y2 - 48, x2 - 28, y2 - 32)
    draw.rounded_rectangle(track, radius=8, fill=(77, 87, 104, 220))
    draw.rounded_rectangle(
        (track[0], track[1], int(track[0] + (track[2] - track[0]) * 0.8), track[3]),
        radius=8,
        fill=ORANGE,
    )

    # List card: four status rows, with the final row still in progress.
    x1, y1, x2, y2 = boxes[1]
    for row, color in enumerate((GREEN, GREEN, TEAL, ORANGE)):
        cy = y1 + 36 + row * 38
        draw.ellipse((x1 + 30, cy, x1 + 47, cy + 17), fill=color)
        width_fraction = (0.72, 0.58, 0.78, 0.5)[row]
        draw.rounded_rectangle(
            (x1 + 68, cy + 2, x1 + 68 + int((x2 - x1 - 106) * width_fraction), cy + 15),
            radius=6,
            fill=WHITE if row == 3 else MUTED,
        )

    # Trend card: a simple semantic line chart and target rule.
    x1, y1, x2, y2 = boxes[2]
    draw.line((x1 + 28, y1 + 56, x2 - 28, y1 + 56), fill=(255, 255, 255, 54), width=3)
    points = [
        (x1 + 32, y2 - 45),
        (x1 + 105, y2 - 78),
        (x1 + 175, y2 - 62),
        (x1 + 245, y2 - 118),
        (x2 - 34, y2 - 142),
    ]
    draw.line(points, fill=TEAL, width=11, joint="curve")
    for x, y in points:
        draw.ellipse((x - 7, y - 7, x + 7, y + 7), fill=TEAL)

    # Breakdown card: compact vertical bars and a headline capsule.
    x1, y1, x2, y2 = boxes[3]
    draw.rounded_rectangle((x1 + 28, y1 + 28, x1 + 160, y1 + 52), radius=12, fill=WHITE)
    baseline = y2 - 34
    bar_w = 28
    for index, (fraction, color) in enumerate(
        ((0.45, BLUE), (0.72, TEAL), (0.56, PURPLE), (0.86, BLUE), (0.66, TEAL))
    ):
        left = x1 + 34 + index * 58
        top = baseline - int((card_h - 110) * fraction)
        draw.rounded_rectangle((left, top, left + bar_w, baseline), radius=14, fill=color)

    panel.putalpha(ImageChops.multiply(panel.getchannel("A"), rounded_mask(size, 52)))
    return panel


def mini_panel(size: tuple[int, int], accent: tuple[int, int, int, int], *, chart: bool) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        (2, 2, width - 3, height - 3),
        radius=42,
        fill=(10, 17, 31, 222),
        outline=(203, 220, 255, 70),
        width=3,
    )
    draw.ellipse((40, 38, 64, 62), fill=accent)
    draw.rounded_rectangle((86, 39, width - 60, 59), radius=10, fill=MUTED)
    if chart:
        pts = [
            (42, height - 70),
            (126, height - 118),
            (214, height - 92),
            (302, height - 164),
            (width - 45, height - 136),
        ]
        draw.line(pts, fill=accent, width=12, joint="curve")
    else:
        for row, fraction in enumerate((0.76, 0.6, 0.84, 0.5)):
            y = 104 + row * 48
            draw.ellipse((42, y, 59, y + 17), fill=GREEN if row < 3 else ORANGE)
            draw.rounded_rectangle(
                (82, y + 2, 82 + int((width - 132) * fraction), y + 16),
                radius=7,
                fill=WHITE if row == 3 else MUTED,
            )
    image.putalpha(ImageChops.multiply(image.getchannel("A"), rounded_mask(size, 42)))
    return image


def composite_with_shadow(
    canvas: Image.Image,
    image: Image.Image,
    xy: tuple[int, int],
    *,
    blur: int = 35,
    opacity: int = 150,
    offset: tuple[int, int] = (0, 22),
) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = image.getchannel("A")
    shape = Image.new("RGBA", image.size, (0, 0, 0, opacity))
    shape.putalpha(ImageChops.multiply(alpha, Image.new("L", image.size, opacity)))
    shadow.alpha_composite(shape, (xy[0] + offset[0], xy[1] + offset[1]))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(image, xy)


def place_rotated(
    canvas: Image.Image,
    image: Image.Image,
    center: tuple[int, int],
    angle: float,
    *,
    opacity: int = 130,
) -> None:
    rotated = image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    xy = (center[0] - rotated.width // 2, center[1] - rotated.height // 2)
    composite_with_shadow(canvas, rotated, xy, blur=34, opacity=opacity)


def build_universal() -> Image.Image:
    canvas = cover_background((2560, 1440))

    left = mini_panel((520, 360), PURPLE, chart=True)
    right = mini_panel((520, 360), BLUE, chart=False)
    place_rotated(canvas, left, (570, 930), -7.0, opacity=110)
    place_rotated(canvas, right, (1990, 915), 7.0, opacity=110)

    dashboard = glass_panel((1000, 590))
    composite_with_shadow(canvas, dashboard, (780, 585), blur=48, opacity=175, offset=(0, 30))

    title = title_art((960, 220))
    title_xy = ((2560 - title.width) // 2, 205)
    composite_with_shadow(canvas, title, title_xy, blur=24, opacity=125, offset=(0, 12))
    return canvas.convert("RGB")


def build_hero() -> Image.Image:
    canvas = cover_background((3000, 900))

    left = mini_panel((500, 340), PURPLE, chart=True)
    right = mini_panel((500, 340), BLUE, chart=False)
    place_rotated(canvas, left, (1810, 500), -6.0, opacity=105)
    place_rotated(canvas, right, (2555, 480), 6.0, opacity=105)

    dashboard = glass_panel((900, 530))
    composite_with_shadow(canvas, dashboard, (1770, 185), blur=44, opacity=175, offset=(0, 26))

    title = title_art((980, 230))
    title_xy = (620, (900 - title.height) // 2)
    inside(
        (title_xy[0], title_xy[1], title_xy[0] + title.width, title_xy[1] + title.height),
        HERO_SAFE_AREA,
    )
    composite_with_shadow(canvas, title, title_xy, blur=24, opacity=130, offset=(0, 12))
    return canvas.convert("RGB")


def build_icon() -> Image.Image:
    return ImageOps.fit(
        Image.open(APP_ICON).convert("RGB"),
        (512, 512),
        method=Image.Resampling.LANCZOS,
    )


def build_logo() -> Image.Image:
    # Preserve the original pixels and alpha: the source already fits Meta's
    # 360px minimum and 9000x1440 maximum logo envelope.
    return Image.open(MARK).convert("RGBA")


def build_spatial_background() -> Image.Image:
    # The Store needs an opaque base layer. Reusing the cover atmosphere keeps
    # the hover tile in the same campaign without baking the mascot into both
    # depth planes.
    return ImageOps.fit(
        Image.open(BACKGROUND).convert("RGB"),
        (180, 180),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.52),
    )


def build_spatial_foreground() -> Image.Image:
    # Meta supplies a 138x138 safe area inside the 180px transparent layer.
    # Fit the exact approved U2 mark into that box and add no extra shadow;
    # Horizon OS applies the depth shadow on hover.
    canvas = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
    mark = contain(trim_alpha(Image.open(MARK)), (138, 138))
    xy = ((180 - mark.width) // 2, (180 - mark.height) // 2)
    inside(
        (xy[0], xy[1], xy[0] + mark.width, xy[1] + mark.height),
        SPATIAL_FOREGROUND_SAFE_AREA,
    )
    canvas.alpha_composite(mark, xy)
    return canvas


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def safe_area_preview(
    image: Image.Image,
    safe_area: tuple[int, int, int, int],
) -> Image.Image:
    preview = image.convert("RGBA")
    dim_alpha = Image.new("L", image.size, 150)
    ImageDraw.Draw(dim_alpha).rectangle(safe_area, fill=0)
    dim = Image.new("RGBA", image.size, (230, 235, 242, 0))
    dim.putalpha(dim_alpha)
    preview.alpha_composite(dim)
    ImageDraw.Draw(preview).rectangle(safe_area, outline=(31, 139, 255, 255), width=8)
    return preview.convert("RGB")


def build_previews(outputs: dict[str, Image.Image]) -> None:
    universal = outputs[UNIVERSAL_NAME]
    # These are QA views only. Meta's Universal Basic Asset tool generates its
    # own cover variants; centered crops make the most punishing common case
    # visible before upload.
    square = ImageOps.fit(universal, (1440, 1440), centering=(0.5, 0.5))
    portrait = ImageOps.fit(universal, (1008, 1440), centering=(0.5, 0.5))
    save(square, PREVIEW_DIR / "universal-centered-square-preview.png")
    save(portrait, PREVIEW_DIR / "universal-centered-portrait-preview.png")
    save(
        safe_area_preview(outputs[HERO_NAME], HERO_SAFE_AREA),
        PREVIEW_DIR / "hero-safe-area-preview.png",
    )

    spatial = outputs[SPATIAL_BACKGROUND_NAME].convert("RGBA")
    spatial.alpha_composite(outputs[SPATIAL_FOREGROUND_NAME])
    save(spatial.convert("RGB"), PREVIEW_DIR / "spatialized-tile-flat-preview.png")


def validate(outputs: dict[str, Image.Image]) -> None:
    expected = {
        UNIVERSAL_NAME: ((2560, 1440), "RGB"),
        HERO_NAME: ((3000, 900), "RGB"),
        ICON_NAME: ((512, 512), "RGB"),
        LOGO_NAME: ((1254, 1254), "RGBA"),
        SPATIAL_BACKGROUND_NAME: ((180, 180), "RGB"),
        SPATIAL_FOREGROUND_NAME: ((180, 180), "RGBA"),
    }
    for name, image in outputs.items():
        if (image.size, image.mode) != expected[name]:
            raise AssertionError(
                f"Invalid {name}: got {image.size} {image.mode}, expected {expected[name]}"
            )
    if outputs[LOGO_NAME].getchannel("A").getextrema() != (0, 255):
        raise AssertionError("Transparent logo must contain both clear and opaque pixels")
    foreground = outputs[SPATIAL_FOREGROUND_NAME]
    if foreground.getchannel("A").getextrema() != (0, 255):
        raise AssertionError("Spatial foreground must contain both clear and opaque pixels")
    bbox = foreground.getbbox()
    if bbox is None:
        raise AssertionError("Spatial foreground cannot be empty")
    inside(bbox, SPATIAL_FOREGROUND_SAFE_AREA)


def main() -> None:
    missing = [path for path in (BACKGROUND, APP_ICON, MARK, WORDMARK) if not path.exists()]
    if missing:
        raise SystemExit("Missing Horizon Store source(s):\n" + "\n".join(map(str, missing)))

    outputs = {
        UNIVERSAL_NAME: build_universal(),
        HERO_NAME: build_hero(),
        ICON_NAME: build_icon(),
        LOGO_NAME: build_logo(),
        SPATIAL_BACKGROUND_NAME: build_spatial_background(),
        SPATIAL_FOREGROUND_NAME: build_spatial_foreground(),
    }
    validate(outputs)
    for name, image in outputs.items():
        save(image, OUTPUT_DIR / name)
    build_previews(outputs)

    manifest = {
        "sourceSha256": {
            str(path.relative_to(REPO_ROOT)): sha256(path)
            for path in (BACKGROUND, APP_ICON, MARK, WORDMARK)
        },
        "assets": [
            {
                "filename": name,
                "dimensions": list(image.size),
                "mode": image.mode,
                "sha256": sha256(OUTPUT_DIR / name),
            }
            for name, image in outputs.items()
        ],
    }
    manifest_path = OUTPUT_DIR / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    for name in outputs:
        print(OUTPUT_DIR / name)
    print(manifest_path)


if __name__ == "__main__":
    main()
