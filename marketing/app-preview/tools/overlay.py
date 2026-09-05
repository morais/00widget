from __future__ import annotations

from pathlib import Path
from typing import Any


class OverlayError(RuntimeError):
    pass


STYLE = {
    "prompt": {"fontSize": 44, "maxLines": 3, "radius": 34, "paddingX": 42, "paddingY": 32},
    "headline": {"fontSize": 52, "maxLines": 3, "radius": 38, "paddingX": 46, "paddingY": 36},
    "caption": {"fontSize": 35, "maxLines": 3, "radius": 28, "paddingX": 36, "paddingY": 26},
}


def _font_path(style: str) -> str:
    rounded = Path("/System/Library/Fonts/SFNSRounded.ttf")
    regular = Path("/System/Library/Fonts/SFNS.ttf")
    selected = rounded if style == "headline" else regular
    if not selected.is_file():
        raise OverlayError(f"system font not found: {selected}")
    return str(selected)


def _wrap(text: str, font: Any, max_width: int, max_lines: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if not current or font.getlength(candidate) <= max_width:
            current = candidate
            continue
        lines.append(current)
        current = word
    if current:
        lines.append(current)
    if len(lines) > max_lines:
        raise OverlayError(
            f"overlay needs {len(lines)} lines but style allows {max_lines}; shorten the copy"
        )
    return lines


def _text_metrics(font: Any, lines: list[str]) -> tuple[int, int, tuple[int, int, int, int]]:
    sample_box = font.getbbox("Ag")
    line_height = sample_box[3] - sample_box[1]
    line_spacing = max(10, int(line_height * 0.28))
    text_height = len(lines) * line_height + max(0, len(lines) - 1) * line_spacing
    return text_height, line_spacing, sample_box


def render_overlay(spec: dict[str, Any], width: int, destination: Path) -> dict[str, int]:
    try:
        from PIL import Image, ImageDraw, ImageFilter, ImageFont
    except ImportError as exc:
        raise OverlayError(
            "Pillow is required for rounded prompt cards. Install scripts/requirements.txt."
        ) from exc

    style_name = spec["style"]
    style = STYLE[style_name]
    requested_width = int(spec.get("width", width))
    padding_x = int(style["paddingX"])
    base_padding_y = int(style["paddingY"])
    base_font_size = int(style["fontSize"])
    font_path = _font_path(style_name)
    base_font = ImageFont.truetype(font_path, base_font_size)
    base_lines = _wrap(
        spec["text"], base_font, requested_width - 2 * padding_x, int(style["maxLines"])
    )
    base_text_height, _, _ = _text_metrics(base_font, base_lines)
    base_card_height = base_text_height + 2 * base_padding_y

    # Small-print disclosure under the main copy (the App Store preview's
    # login/purchase notice). Caption-sized, at most two lines, part of the
    # same card so the brand beat and the disclosure share one beat.
    subtext = str(spec.get("subtext", "")).strip()
    sub_lines: list[str] = []
    sub_font = None
    sub_height = 0
    sub_gap = 0
    if subtext:
        sub_style = STYLE["caption"]
        sub_font = ImageFont.truetype(_font_path("caption"), int(sub_style["fontSize"]))
        sub_lines = _wrap(
            subtext, sub_font, requested_width - 2 * padding_x, 2
        )
        sub_height, _, sub_box = _text_metrics(sub_font, sub_lines)
        sub_gap = max(10, int(base_text_height * 0.28))
        base_card_height += sub_height + sub_gap

    height_scale = float(spec.get("heightScale", 1))
    card_height = round(base_card_height * height_scale)
    padding_y = round(base_padding_y * height_scale)
    available_text_height = card_height - 2 * padding_y
    scaled_max_lines = max(int(style["maxLines"]), round(int(style["maxLines"]) * height_scale))
    font = base_font
    lines = base_lines
    text_height, line_spacing, sample_box = _text_metrics(font, lines)
    fitted = text_height + sub_height <= available_text_height
    for font_size in range(round(base_font_size * height_scale), int(base_font_size * 0.6) - 1, -1):
        candidate_font = ImageFont.truetype(font_path, font_size)
        try:
            candidate_lines = _wrap(
                spec["text"],
                candidate_font,
                requested_width - 2 * padding_x,
                scaled_max_lines,
            )
        except OverlayError:
            continue
        candidate_height, candidate_spacing, candidate_box = _text_metrics(
            candidate_font, candidate_lines
        )
        if candidate_height + sub_height <= available_text_height:
            font = candidate_font
            lines = candidate_lines
            text_height = candidate_height
            line_spacing = candidate_spacing
            sample_box = candidate_box
            fitted = True
            break
    if not fitted:
        raise OverlayError("overlay copy with subtext does not fit; shorten the copy")

    line_height = sample_box[3] - sample_box[1]
    shadow_margin = 24
    canvas = Image.new("RGBA", (requested_width + shadow_margin * 2, card_height + shadow_margin * 2))

    shadow = Image.new("RGBA", canvas.size)
    shadow_draw = ImageDraw.Draw(shadow)
    rect = (
        shadow_margin,
        shadow_margin,
        shadow_margin + requested_width,
        shadow_margin + card_height,
    )
    shadow_draw.rounded_rectangle(
        (rect[0], rect[1] + 7, rect[2], rect[3] + 7),
        radius=round(int(style["radius"]) * height_scale),
        fill=(0, 0, 0, 54),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12)))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        rect,
        radius=round(int(style["radius"]) * height_scale),
        fill=(250, 250, 249, 238),
        outline=(255, 255, 255, 184),
        width=1,
    )
    y = shadow_margin + (card_height - text_height) / 2 - sample_box[1]
    if sub_lines:
        # The disclosure joins the block: recenter on main text plus gap
        # plus subtext so neither half drifts off-center.
        block = text_height + sub_gap + sub_height
        y = shadow_margin + (card_height - block) / 2 - sample_box[1]
    for line in lines:
        line_width = font.getlength(line)
        x = shadow_margin + (requested_width - line_width) / 2
        draw.text((x, y), line, font=font, fill=(24, 24, 26, 255))
        y += line_height + line_spacing
    if sub_lines:
        y += sub_gap - line_spacing
        for line in sub_lines:
            line_width = sub_font.getlength(line)
            x = shadow_margin + (requested_width - line_width) / 2
            draw.text((x, y), line, font=sub_font, fill=(110, 110, 115, 255))
            y += sub_box[3] - sub_box[1] + max(6, int((sub_box[3] - sub_box[1]) * 0.28))

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination)
    return {
        "width": canvas.width,
        "height": canvas.height,
        "baseHeight": base_card_height + shadow_margin * 2,
        "fontSize": font.size,
        "lines": len(lines),
        "sublines": len(sub_lines),
    }
