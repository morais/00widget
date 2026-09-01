#!/usr/bin/env python3
"""Compose promotional App Store screenshots from the canonical raw captures.

Raw XCUITest captures stay under ios/build/screenshots. This script only reads
those files and writes the headline-led marketing compositions to the separate
ios/build/promotional-screenshots tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


IOS_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE_ROOT = IOS_ROOT / "build" / "screenshots"
DEFAULT_OUTPUT_ROOT = IOS_ROOT / "build" / "promotional-screenshots"
FONT_REGULAR = Path("/System/Library/Fonts/SFNS.ttf")
FONT_BOLD = Path("/System/Library/Fonts/SFNS.ttf")

DEVICE_SETS = ("iphone-6.3", "iphone-6.5", "ipad")
EXPECTED_DIMENSIONS = {
    "iphone-6.3": (1206, 2622),
    "iphone-6.5": (1284, 2778),
    "ipad": (2064, 2752),
}


@dataclass(frozen=True)
class Promotion:
    filename: str
    headline: str
    supporting: str


PROMOTIONS = (
    Promotion(
        "screenshot-home-widgets.png",
        "Widgets for all your agents.",
        "Connect ChatGPT, Claude, or any MCP host.",
    ),
    Promotion(
        "screenshot-home-insights.png",
        "From conversation to Home Screen.",
        "Publish through MCP—no integration code required.",
    ),
    Promotion(
        "screenshot-home-metrics.png",
        "Connect what you've already built.",
        "Ask Codex or Claude Code to add 00Widget to any app, script, or automation.",
    ),
    Promotion(
        "screenshot-insights.png",
        "See the whole picture.",
        "Turn agent output into clear, useful insights.",
    ),
    Promotion(
        "screenshot-widgets.png",
        "Every agent. One dashboard.",
        "Follow status, progress, and actions in one place.",
    ),
    Promotion(
        "screenshot-activities.png",
        "Live Activities that keep up.",
        "Follow changing work on the Lock Screen and Dynamic Island.",
    ),
)


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


def draw_device(
    canvas: Image.Image,
    source: Image.Image,
    device_set: str,
    top: int,
) -> None:
    width, height = canvas.size
    is_ipad = device_set == "ipad"
    outer_width = round(width * 0.88)
    chrome = max(8, round(width * (0.007 if is_ipad else 0.0085)))
    bezel = max(8, round(width * (0.009 if is_ipad else 0.0105)))
    screen_width = outer_width - 2 * (chrome + bezel)
    scale = screen_width / source.width
    screen_size = (screen_width, round(source.height * scale))
    screen = source.resize(screen_size, Image.Resampling.LANCZOS)

    screen_radius = round(screen_width * (0.038 if is_ipad else 0.074))
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
        width=max(3, bezel // 2),
    )
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

    draw_device(canvas, source, device_set, device_top)

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
    args = parser.parse_args()

    if not FONT_REGULAR.is_file():
        raise SystemExit(f"Missing system font: {FONT_REGULAR}")

    selected_sets = DEVICE_SETS if args.set == "all" else (args.set,)
    generated_sets: list[dict[str, object]] = []
    for device_set in selected_sets:
        source_directory = args.source_root / device_set
        output_directory = args.output_root / device_set
        expected_size = EXPECTED_DIMENSIONS[device_set]
        items: list[dict[str, object]] = []
        for promotion in PROMOTIONS:
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
            items.append(compose(source_path, output_path, promotion, device_set))
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


if __name__ == "__main__":
    main()
