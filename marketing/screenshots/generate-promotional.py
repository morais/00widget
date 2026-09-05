#!/usr/bin/env python3
"""Compose promotional App Store screenshots from the canonical raw captures.

Raw XCUITest captures stay under artifacts/screenshots/raw. This script only
reads those files and writes the headline-led marketing compositions to the
separate artifacts/screenshots/promotional tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE_ROOT = REPO_ROOT / "artifacts" / "screenshots" / "raw"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "artifacts" / "screenshots" / "promotional"
FONT_REGULAR = Path("/System/Library/Fonts/SFNS.ttf")
FONT_BOLD = Path("/System/Library/Fonts/SFNS.ttf")

DEVICE_SETS = ("iphone-6.3", "iphone-6.5", "ipad", "tvos")
EXPECTED_DIMENSIONS = {
    "iphone-6.3": (1206, 2622),
    "iphone-6.5": (1284, 2778),
    "ipad": (2064, 2752),
    "tvos": (1920, 1080),
}


@dataclass(frozen=True)
class Promotion:
    filename: str
    headline: str
    supporting: str


# The sequence Apple shows first is the sequence that has to carry the
# product, so the order here is the argument: what the agents are doing, all
# of them at once, then the surfaces that bring it to you without opening
# anything. The hero shows the *compact* Island, because expanded it is drawn
# over the first row of widgets and covers their titles.
#
# The expanded presentation was then inset into the Lock Screen frame to keep
# it in the sequence, and that is now gone: composed against a real Lock Screen
# capture it showed the same four lines as the card beneath it, which reads as
# one thing printed twice rather than as two surfaces. The Island is still in
# the sequence — frame 1 shows it doing its job at the size a person sees it.
# `screenshot-island-expanded.png` is still captured: it costs one shot, it is
# the only record of that presentation, and the App Preview is where showing it
# in motion will earn its place.
PROMOTIONS = (
    Promotion(
        "screenshot-home-widgets.png",
        "Know what every agent is doing.",
        "Live progress, results, and approvals—right on your Home Screen.",
    ),
    Promotion(
        "screenshot-home-insights.png",
        "One dashboard. Every agent.",
        "See the work that’s done, in motion, and waiting on you.",
    ),
    Promotion(
        "screenshot-lock-activity.png",
        "Follow every step live.",
        "Progress, completed steps, and the next decision—right on your "
        "Lock Screen.",
    ),
    Promotion(
        "screenshot-island-expanded.png",
        "Keep live work in sight.",
        "Progress and approvals stay visible in the Dynamic Island.",
    ),
    Promotion(
        "screenshot-home-metrics.png",
        "Four agents. One widget.",
        "Trends, budgets, and run history—without opening anything.",
    ),
    Promotion(
        "screenshot-widgets.png",
        "Step in at the right moment.",
        "Approve, retry, or open the exact task without hunting through chat.",
    ),
    Promotion(
        "screenshot-insights.png",
        "Updates become decisions.",
        "Trends, run history, breakdowns, and concise agent briefings.",
    ),
    Promotion(
        "screenshot-activities.png",
        "Every active job. One place.",
        "See what is running, current, and complete.",
    ),
)

TV_PROMOTIONS = (
    Promotion(
        "screenshot-tv-insights.png",
        "Your agent control room.",
        "See every launch task, metric, and exception at a glance.",
    ),
    Promotion(
        "screenshot-tv-widgets.png",
        "Live work. Shared screen.",
        "Keep the whole room aligned without opening another dashboard.",
    ),
    Promotion(
        "screenshot-tv-card-detail.png",
        "The detail is one click away.",
        "Open any card for the trend, briefing, or action behind it.",
    ),
)


#: The Island frame is a close-up of a presentation only one capture device
#: has. The other sets omit it rather than fake it, which is why the promotional
#: counts differ per device — eight on 6.3, seven elsewhere.
ISLAND_FRAME = "screenshot-island-expanded.png"


def promotions_for(device_set: str) -> tuple[Promotion, ...]:
    if device_set == "tvos":
        return TV_PROMOTIONS
    if device_set == "iphone-6.3":
        return PROMOTIONS
    return tuple(p for p in PROMOTIONS if p.filename != ISLAND_FRAME)


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    path = FONT_BOLD if bold else FONT_REGULAR
    selected = ImageFont.truetype(str(path), size=size)
    if bold:
        selected.set_variation_by_name("Bold")
    return selected


def text_length(draw: ImageDraw.ImageDraw, text: str, selected_font: ImageFont.FreeTypeFont) -> float:
    return draw.textlength(text, font=selected_font)


def wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    selected_font: ImageFont.FreeTypeFont,
    max_width: int,
) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if current and text_length(draw, candidate, selected_font) > max_width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def draw_lines(
    draw: ImageDraw.ImageDraw,
    lines: list[str],
    xy: tuple[int, int],
    selected_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int],
    spacing: int,
) -> int:
    x, y = xy
    ascent, descent = selected_font.getmetrics()
    line_height = ascent + descent
    for line in lines:
        draw.text((x, y), line, font=selected_font, fill=fill)
        y += line_height + spacing
    return y


def background(size: tuple[int, int]) -> Image.Image:
    width, height = size
    top = (255, 252, 247)
    bottom = (239, 247, 255)
    gradient = Image.new("RGB", (1, height))
    pixels = gradient.load()
    for y in range(height):
        amount = y / max(1, height - 1)
        pixels[0, y] = tuple(
            round(start + (end - start) * amount)
            for start, end in zip(top, bottom)
        )
    return gradient.resize((width, height))


def rounded_image(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1),
        radius=radius,
        fill=255,
    )
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result


def cubic_points(
    start: tuple[float, float],
    control_1: tuple[float, float],
    control_2: tuple[float, float],
    end: tuple[float, float],
    steps: int = 24,
) -> list[tuple[int, int]]:
    """Sample a cubic Bezier while retaining its exact endpoints."""
    points: list[tuple[int, int]] = []
    for index in range(1, steps + 1):
        amount = index / steps
        inverse = 1 - amount
        x = (
            inverse**3 * start[0]
            + 3 * inverse**2 * amount * control_1[0]
            + 3 * inverse * amount**2 * control_2[0]
            + amount**3 * end[0]
        )
        y = (
            inverse**3 * start[1]
            + 3 * inverse**2 * amount * control_1[1]
            + 3 * inverse * amount**2 * control_2[1]
            + amount**3 * end[1]
        )
        points.append((round(x), round(y)))
    return points


def iphone_14_plus_notch() -> list[tuple[int, int]]:
    """Return Apple's iPhone 14 Plus framebuffer-notch silhouette.

    These are the native 1284x2778 coordinates from Xcode's bundled
    iPhone 14 Plus framebuffer mask, transformed into top-left image space.
    """
    points: list[tuple[int, int]] = [(908, 0), (884, 23)]
    current = (884.1562, 23.321)
    curves = (
        ((883.9402, 30.217), (883.8632, 36.713), (882.7812, 43.877)),
        ((881.7432, 50.792), (879.9092, 57.122), (876.9232, 63.266)),
        ((873.0762, 71.175), (867.4792, 78.409), (860.6272, 84.350)),
        ((853.8842, 90.202), (846.2742, 94.513), (838.0472, 97.181)),
        ((824.5412, 101.562), (811.1112, 101.014), (796.8342, 101.014)),
    )
    for control_1, control_2, end in curves:
        points.extend(cubic_points(current, control_1, control_2, end))
        current = end

    points.append((487, 101))
    current = (487.1592, 101.014)
    curves = (
        ((472.8882, 101.014), (459.4532, 101.562), (445.9462, 97.181)),
        ((437.7252, 94.513), (430.1102, 90.202), (423.3732, 84.350)),
        ((416.5202, 78.409), (410.9242, 71.175), (407.0772, 63.266)),
        ((404.0912, 57.122), (402.2572, 50.792), (401.2132, 43.877)),
        ((400.1362, 36.713), (400.0592, 30.217), (399.8432, 23.321)),
        ((399.7412, 20.157), (399.8112, 16.877), (399.0482, 13.311)),
        ((398.3082, 9.879), (396.9142, 6.937), (394.5902, 4.695)),
        ((392.2722, 2.448), (389.2792, 1.149), (385.8212, 0.518)),
        ((382.2432, -0.137), (378.9442, 0.000), (375.7992, 0.000)),
    )
    for control_1, control_2, end in curves:
        points.extend(cubic_points(current, control_1, control_2, end))
        current = end
    return points


def has_dynamic_island(screen: Image.Image) -> bool:
    """Detect the compact or expanded Island already rendered by SpringBoard."""
    # The empty iPhone 16 Pro Island is 126x37 points at 3x. Sample its
    # interior, where compact and expanded Live Activities remain black.
    interior = screen.crop((444, 52, 762, 143)).convert("L")
    histogram = interior.histogram()
    dark_pixels = sum(histogram[:32])
    return dark_pixels / (interior.width * interior.height) > 0.75


def add_iphone_hardware_cutout(
    screen: Image.Image,
    device_set: str,
) -> None:
    draw = ImageDraw.Draw(screen)

    if device_set == "iphone-6.5":
        # Use the exact smaller notch from the last notched iPhone in this
        # resolution class, rather than approximating it with a rounded box.
        draw.polygon(iphone_14_plus_notch(), fill=(0, 0, 0))
        return

    if device_set == "iphone-6.3" and not has_dynamic_island(screen):
        # Native iPhone 16 Pro geometry: 126x37 points at 3x. Its vertical
        # placement is also measured from the compact Live Activity in the raw
        # SpringBoard capture, so empty and active states share one centerline.
        draw.rounded_rectangle(
            (414, 42, 792, 153),
            radius=56,
            fill=(0, 0, 0),
        )


def draw_device(
    canvas: Image.Image,
    source: Image.Image,
    device_set: str,
    top: int,
) -> None:
    width, height = canvas.size
    is_ipad = device_set == "ipad"
    outer_width = round(width * 0.88)
    if is_ipad:
        # The 13-inch iPad Pro display occupies about 92% of the physical
        # device width. Keep that real, uniform black bezel instead of scaling
        # up the much thinner iPhone treatment.
        chrome = max(8, round(width * 0.006))
        bezel = max(8, round(width * 0.0305))
    else:
        chrome = max(8, round(width * 0.0085))
        bezel = max(8, round(width * 0.0105))
    screen_width = outer_width - 2 * (chrome + bezel)
    scale = screen_width / source.width
    screen_size = (screen_width, round(source.height * scale))
    screen = source.copy()
    add_iphone_hardware_cutout(screen, device_set)
    screen = screen.resize(screen_size, Image.Resampling.LANCZOS)

    # Xcode's iPad Pro 13-inch (M4) framebuffer mask has a native 60 px
    # display radius. Scale that device coordinate with the raw capture.
    screen_radius = round(60 * scale) if is_ipad else round(screen_width * 0.074)
    outer_radius = screen_radius + chrome + bezel
    screen = rounded_image(screen, screen_radius)
    outer_height = screen.height + 2 * (chrome + bezel)
    outer_x = (width - outer_width) // 2
    screen_x = outer_x + chrome + bezel
    screen_y = top + chrome + bezel

    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    shadow_offset = round(height * 0.009)
    shadow_draw.rounded_rectangle(
        (
            outer_x,
            top + shadow_offset,
            outer_x + outer_width,
            top + outer_height + shadow_offset,
        ),
        radius=outer_radius,
        fill=(6, 21, 42, 122),
    )
    shadow_layer = shadow_layer.filter(
        ImageFilter.GaussianBlur(radius=max(14, round(width * 0.018)))
    )
    canvas.alpha_composite(shadow_layer)

    draw = ImageDraw.Draw(canvas)
    # Physical controls sit outside the case and make the silhouette read as
    # hardware rather than a rounded screenshot card.
    if not is_ipad:
        control_width = max(7, round(width * 0.006))
        control_x = outer_x - control_width + 2
        for start, length in ((0.16, 0.035), (0.225, 0.058), (0.305, 0.058)):
            y = top + round(outer_height * start)
            draw.rounded_rectangle(
                (control_x, y, outer_x + 2, y + round(outer_height * length)),
                radius=control_width // 2,
                fill=(48, 50, 54),
                outline=(133, 136, 141),
                width=max(1, chrome // 5),
            )
        control_x = outer_x + outer_width - 2
        y = top + round(outer_height * 0.235)
        draw.rounded_rectangle(
            (
                control_x,
                y,
                control_x + control_width,
                y + round(outer_height * 0.092),
            ),
            radius=control_width // 2,
            fill=(48, 50, 54),
            outline=(133, 136, 141),
            width=max(1, chrome // 5),
        )

    draw.rounded_rectangle(
        (outer_x, top, outer_x + outer_width, top + outer_height),
        radius=outer_radius,
        fill=(38, 40, 45),
        outline=(174, 178, 184),
        width=max(3, chrome // 2),
    )
    draw.rounded_rectangle(
        (
            outer_x + chrome,
            top + chrome,
            outer_x + outer_width - chrome,
            top + outer_height - chrome,
        ),
        radius=outer_radius - chrome,
        fill=(3, 4, 6),
        outline=(104, 108, 114),
        width=max(2, chrome // 3),
    )
    canvas.alpha_composite(screen, (screen_x, screen_y))
    ImageDraw.Draw(canvas).rounded_rectangle(
        (
            screen_x,
            screen_y,
            screen_x + screen.width - 1,
            screen_y + screen.height - 1,
        ),
        radius=screen_radius,
        outline=(0, 0, 0, 210),
        width=max(2, chrome // 3) if is_ipad else max(3, bezel // 2),
    )



def island_bounds(screen: Image.Image) -> tuple[int, int, int, int]:
    """Where SpringBoard drew the expanded Island in a raw capture.

    Measured rather than hardcoded, because the presentation's height follows
    the number of rows the activity draws — a fixed crop would silently slice
    a row off the moment the fixture gains or loses one. The Island is the
    only thing at the top of a Home Screen that is both near-black and most of
    the width, so a row is part of it when it is mostly black.
    """
    grey = screen.convert("L")
    width, height = grey.size
    pixels = grey.load()
    band = range(0, round(height * 0.4))
    rows = [
        y
        for y in band
        if sum(1 for x in range(0, width, 4) if pixels[x, y] < 24)
        > (width // 4) * 0.55
    ]
    if not rows:
        raise SystemExit(
            "no expanded Dynamic Island found in the inset source: the capture "
            "did not reach the expanded presentation"
        )
    top, bottom = rows[0], rows[-1]
    # Walk out from the centre of the band rather than collecting every dark
    # column: a Home Screen wallpaper can be near-black at the edges of the
    # same rows, and a scan that merely looks for dark pixels then reports the
    # whole width. The Island is one contiguous run through the middle.
    # A column belongs to the Island only if it is dark down the *whole* band,
    # not merely at one row. Walking out along a single row runs straight into
    # a dark wallpaper — the 6.3-inch capture's is navy — and the crop then
    # carries a slab of it either side, which the rounded mask leaves as a pale
    # halo along two edges.
    # Sample just inside the band's top and bottom edges: those rows are inside
    # the pill but clear of its text, so they are black right across it, while
    # the wallpaper either side is only *sometimes* dark. Sampling every row
    # instead would reject every column the white text passes through.
    inset = max(2, (bottom - top) // 12)
    probes = (top + inset, bottom - inset)

    def is_island_column(x: int) -> bool:
        return all(pixels[x, y] < 24 for y in probes)

    centre = width // 2
    left, right = centre, centre
    while left > 0 and is_island_column(left - 1):
        left -= 1
    while right < width - 1 and is_island_column(right + 1):
        right += 1
    if right - left < width * 0.6 or bottom - top < height * 0.05:
        raise SystemExit(
            "the inset source's dark region is too small to be an expanded "
            f"Dynamic Island: {right - left}x{bottom - top}"
        )
    return left, top, right, bottom


def draw_island_closeup(canvas: Image.Image, source: Image.Image) -> None:
    """Draw the expanded Island large, alone, and with nothing behind it.

    An earlier version pasted this over the Lock Screen frame as an inset, and
    it was rejected on sight: an expanded Island floating inside a locked phone
    above a banner repeating the same title, progress and rows reads as a
    compositing mistake rather than as proof of two surfaces. So it gets its
    own frame, cropped out of a real Home Screen capture, and it is the only
    thing in it — no second system surface underneath, and the same activity
    never shown twice in one phone.

    There is no device outline for the same reason. The Island *is* hardware
    and screen at once; drawing a phone around a close-up of it would either
    repeat the bezel at the wrong scale or shrink the subject back to the size
    the hero already shows it at.
    """
    width, height = canvas.size
    island = source.crop(island_bounds(source))

    # Large, because the subject is a 3.25:1 pill in a 1:2.17 canvas and
    # anything smaller reads as an object lost in a page rather than as the
    # thing the frame is about. The space around it is then deliberate.
    target_width = round(width * 0.92)
    scale = target_width / island.width
    island = island.resize(
        (target_width, round(island.height * scale)), Image.Resampling.LANCZOS
    )
    radius = round(island.height * 0.20)
    island = rounded_image(island, radius)

    x = (width - island.width) // 2
    # Centred in the room below the copy block rather than in the canvas, so
    # the space above and below the subject is even.
    y = round(height * 0.58) - island.height // 2

    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow_layer).rounded_rectangle(
        (
            x,
            y + round(height * 0.008),
            x + island.width,
            y + island.height + round(height * 0.008),
        ),
        radius=radius,
        fill=(6, 21, 42, 150),
    )
    canvas.alpha_composite(
        shadow_layer.filter(ImageFilter.GaussianBlur(radius=max(16, round(width * 0.020))))
    )
    canvas.alpha_composite(island, (x, y))


def compose(
    source_path: Path,
    output_path: Path,
    promotion: Promotion,
    device_set: str,
) -> dict[str, object]:
    source = Image.open(source_path).convert("RGB")
    width, height = source.size
    canvas = background(source.size).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    side = round(width * 0.073)
    copy_width = width - side * 2
    top_padding = round(height * 0.040)
    device_top = round(height * 0.205)

    headline_font = font(round(height * 0.038), bold=True)
    supporting_font = font(round(height * 0.0155))
    headline_lines = wrap_text(draw, promotion.headline, headline_font, copy_width)
    supporting_lines = wrap_text(draw, promotion.supporting, supporting_font, copy_width)

    y = draw_lines(
        draw,
        headline_lines,
        (side, top_padding),
        headline_font,
        (8, 20, 38),
        round(height * 0.004),
    )
    rule_y = y + round(height * 0.008)
    rule_width = round(width * 0.112)
    rule_height = max(5, round(height * 0.0024))
    draw.rounded_rectangle(
        (side, rule_y, side + rule_width, rule_y + rule_height),
        radius=rule_height // 2,
        fill=(31, 184, 154),
    )
    supporting_y = rule_y + rule_height + round(height * 0.011)
    draw_lines(
        draw,
        supporting_lines,
        (side, supporting_y),
        supporting_font,
        (62, 78, 101),
        round(height * 0.003),
    )

    if promotion.filename == ISLAND_FRAME:
        draw_island_closeup(canvas, source)
    else:
        draw_device(canvas, source, device_set, device_top)

    record: dict[str, object] = {
        "filename": promotion.filename,
        "headline": promotion.headline,
        "supporting": promotion.supporting,
        "sourceSha256": file_hash(source_path),
        "dimensions": [width, height],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output_path, format="PNG", optimize=True)
    record["outputSha256"] = file_hash(output_path)
    return record


def draw_tv(canvas: Image.Image, source: Image.Image) -> None:
    width, height = canvas.size
    outer_width = round(width * 0.73)
    bezel = max(6, round(height * 0.0075))
    screen_width = outer_width - 2 * bezel
    screen_height = round(screen_width * 9 / 16)
    screen = source.resize(
        (screen_width, screen_height),
        Image.Resampling.LANCZOS,
    ).convert("RGBA")
    outer_height = screen_height + 2 * bezel
    outer_x = round(width * 0.315)
    top = round(height * 0.27)
    screen_x = outer_x + bezel
    screen_y = top + bezel

    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    shadow_draw.rectangle(
        (outer_x, top + 14, outer_x + outer_width, top + outer_height + 14),
        fill=(6, 21, 42, 132),
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=28))
    canvas.alpha_composite(shadow_layer)

    draw = ImageDraw.Draw(canvas)
    draw.rectangle(
        (outer_x, top, outer_x + outer_width, top + outer_height),
        fill=(13, 14, 16),
        outline=(91, 94, 99),
        width=2,
    )
    canvas.alpha_composite(screen, (screen_x, screen_y))
    ImageDraw.Draw(canvas).rectangle(
        (
            screen_x,
            screen_y,
            screen_x + screen.width - 1,
            screen_y + screen.height - 1,
        ),
        outline=(0, 0, 0, 230),
        width=2,
    )


def compose_tv(
    source_path: Path,
    output_path: Path,
    promotion: Promotion,
    device_set: str,
) -> dict[str, object]:
    source = Image.open(source_path).convert("RGB")
    width, height = source.size
    canvas = background(source.size).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    side = round(width * 0.047)
    copy_width = round(width * 0.265)
    top_padding = round(height * 0.095)
    headline_font = font(round(height * 0.070), bold=True)
    supporting_font = font(round(height * 0.029))
    headline_lines = wrap_text(draw, promotion.headline, headline_font, copy_width)
    supporting_lines = wrap_text(draw, promotion.supporting, supporting_font, copy_width)

    y = draw_lines(
        draw,
        headline_lines,
        (side, top_padding),
        headline_font,
        (8, 20, 38),
        round(height * 0.008),
    )
    rule_y = y + round(height * 0.018)
    rule_width = round(width * 0.065)
    rule_height = max(5, round(height * 0.006))
    draw.rounded_rectangle(
        (side, rule_y, side + rule_width, rule_y + rule_height),
        radius=rule_height // 2,
        fill=(31, 184, 154),
    )
    draw_lines(
        draw,
        supporting_lines,
        (side, rule_y + rule_height + round(height * 0.025)),
        supporting_font,
        (62, 78, 101),
        round(height * 0.008),
    )
    draw_tv(canvas, source)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output_path, format="PNG", optimize=True)
    return {
        "filename": promotion.filename,
        "headline": promotion.headline,
        "supporting": promotion.supporting,
        "sourceSha256": file_hash(source_path),
        "outputSha256": file_hash(output_path),
        "dimensions": [width, height],
    }


def verify_promotional_screenshots(
    source_root: Path,
    output_root: Path,
    selected_sets: tuple[str, ...],
    generated_after: datetime | None,
) -> None:
    manifest_path = output_root / "promotional-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Cannot read promotional manifest: {error}") from error

    errors: list[str] = []
    try:
        generated_at = datetime.fromisoformat(manifest["generatedAt"])
        if generated_at.tzinfo is None:
            generated_at = generated_at.replace(tzinfo=timezone.utc)
        if generated_after is not None and generated_at < generated_after:
            errors.append("promotional manifest was not produced by this workflow run")
    except (KeyError, TypeError, ValueError):
        errors.append("promotional manifest has an invalid generatedAt value")

    if manifest.get("sourceRoot") != str(source_root.resolve()):
        errors.append("promotional manifest sourceRoot does not match the canonical raw captures")
    if manifest.get("outputRoot") != str(output_root.resolve()):
        errors.append("promotional manifest outputRoot does not match the canonical output directory")

    manifest_sets = manifest.get("sets")
    if not isinstance(manifest_sets, list):
        errors.append("promotional manifest sets value is invalid")
        manifest_sets = []
    by_set: dict[str, list[dict[str, object]]] = {}
    for entry in manifest_sets:
        if not isinstance(entry, dict) or not isinstance(entry.get("deviceSet"), str):
            errors.append("promotional manifest contains an invalid device set")
            continue
        device_set = entry["deviceSet"]
        files = entry.get("files")
        if device_set in by_set:
            errors.append(f"promotional manifest repeats device set {device_set}")
        elif not isinstance(files, list):
            errors.append(f"{device_set}: promotional manifest files value is invalid")
        else:
            by_set[device_set] = files

    if selected_sets == DEVICE_SETS and set(by_set) != set(DEVICE_SETS):
        errors.append(
            "promotional manifest device sets differ from the four canonical sets"
        )

    for device_set in selected_sets:
        expected_promotions = {
            promotion.filename: promotion for promotion in promotions_for(device_set)
        }
        entries = by_set.get(device_set)
        if entries is None:
            errors.append(f"{device_set}: missing from promotional manifest")
            continue
        manifest_files = {
            entry.get("filename"): entry
            for entry in entries
            if isinstance(entry, dict) and isinstance(entry.get("filename"), str)
        }
        if set(manifest_files) != set(expected_promotions):
            missing = sorted(set(expected_promotions) - set(manifest_files))
            extra = sorted(set(manifest_files) - set(expected_promotions))
            errors.append(
                f"{device_set}: promotional manifest file mismatch; "
                f"missing={missing}, extra={extra}"
            )

        output_directory = output_root / device_set
        try:
            disk_files = {
                path.name
                for path in output_directory.iterdir()
                if path.name.startswith("screenshot-") and path.suffix == ".png"
            }
        except OSError as error:
            errors.append(f"{device_set}: cannot read promotional output: {error}")
            continue
        if disk_files != set(expected_promotions):
            missing = sorted(set(expected_promotions) - disk_files)
            extra = sorted(disk_files - set(expected_promotions))
            errors.append(
                f"{device_set}: promotional output mismatch; missing={missing}, extra={extra}"
            )

        for filename, promotion in expected_promotions.items():
            entry = manifest_files.get(filename)
            output_path = output_directory / filename
            source_path = source_root / device_set / filename
            if entry is None or not output_path.is_file() or not source_path.is_file():
                continue
            if entry.get("headline") != promotion.headline:
                errors.append(f"{device_set}/{filename}: headline differs from approved copy")
            if entry.get("supporting") != promotion.supporting:
                errors.append(f"{device_set}/{filename}: supporting line differs from approved copy")
            if entry.get("dimensions") != list(EXPECTED_DIMENSIONS[device_set]):
                errors.append(f"{device_set}/{filename}: manifest dimensions are incorrect")
            if entry.get("sourceSha256") != file_hash(source_path):
                errors.append(f"{device_set}/{filename}: composition is stale for its raw capture")
            if entry.get("outputSha256") != file_hash(output_path):
                errors.append(f"{device_set}/{filename}: output checksum differs from manifest")
            try:
                with Image.open(output_path) as output:
                    if output.size != EXPECTED_DIMENSIONS[device_set]:
                        errors.append(f"{device_set}/{filename}: output dimensions are incorrect")
            except OSError as error:
                errors.append(f"{device_set}/{filename}: cannot read output PNG: {error}")

        print(
            f"  {device_set}: {len(expected_promotions)} promotional screenshots "
            f"at {EXPECTED_DIMENSIONS[device_set][0]}x{EXPECTED_DIMENSIONS[device_set][1]}"
        )

    if errors:
        print("Promotional screenshot verification failed:")
        for error in errors:
            print(f"  - {error}")
        raise SystemExit(1)

    total = sum(len(promotions_for(device_set)) for device_set in selected_sets)
    print(f"✓ all {total} promotional screenshots verified")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument(
        "--set",
        choices=("all", *DEVICE_SETS),
        default="all",
        help="device set to generate (default: all)",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="verify existing promotional screenshots without generating them",
    )
    parser.add_argument(
        "--generated-after",
        help="require the promotional manifest to be at least this ISO-8601 time",
    )
    args = parser.parse_args()

    if not FONT_REGULAR.is_file():
        raise SystemExit(f"Missing system font: {FONT_REGULAR}")

    selected_sets = DEVICE_SETS if args.set == "all" else (args.set,)
    generated_after = None
    if args.generated_after:
        try:
            generated_after = datetime.fromisoformat(
                args.generated_after.replace("Z", "+00:00")
            )
            if generated_after.tzinfo is None:
                generated_after = generated_after.replace(tzinfo=timezone.utc)
        except ValueError as error:
            raise SystemExit(f"Invalid --generated-after value: {error}") from error

    if args.verify_only:
        verify_promotional_screenshots(
            args.source_root,
            args.output_root,
            selected_sets,
            generated_after,
        )
        return

    generated_sets: list[dict[str, object]] = []
    for device_set in selected_sets:
        source_directory = args.source_root / device_set
        output_directory = args.output_root / device_set
        expected_size = EXPECTED_DIMENSIONS[device_set]
        items: list[dict[str, object]] = []
        promotions = promotions_for(device_set)
        composer = compose_tv if device_set == "tvos" else compose
        for promotion in promotions:
            source_path = source_directory / promotion.filename
            if not source_path.is_file():
                raise SystemExit(f"Missing raw capture: {source_path}")
            with Image.open(source_path) as source:
                if source.size != expected_size:
                    raise SystemExit(
                        f"{source_path} is {source.size[0]}x{source.size[1]}; "
                        f"expected {expected_size[0]}x{expected_size[1]}"
                    )
            output_path = output_directory / promotion.filename
            items.append(composer(source_path, output_path, promotion, device_set))
            print(f"✓ {device_set}/{promotion.filename}")
        generated_sets.append({"deviceSet": device_set, "files": items})

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceRoot": str(args.source_root.resolve()),
        "outputRoot": str(args.output_root.resolve()),
        "style": (
            "off-white editorial header, green accent rule, physical device frame, "
            "intentional bottom crop"
        ),
        "sets": generated_sets,
    }
    args.output_root.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output_root / "promotional-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"✓ manifest {manifest_path}")
    verify_promotional_screenshots(
        args.source_root,
        args.output_root,
        selected_sets,
        generated_after,
    )


if __name__ == "__main__":
    main()
