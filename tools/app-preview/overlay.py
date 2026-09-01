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
    padding_y = int(style["paddingY"])
    font = ImageFont.truetype(_font_path(style_name), int(style["fontSize"]))
    lines = _wrap(spec["text"], font, requested_width - 2 * padding_x, int(style["maxLines"]))

    sample_box = font.getbbox("Ag")
    line_height = sample_box[3] - sample_box[1]
    line_spacing = max(10, int(line_height * 0.28))
    text_height = len(lines) * line_height + max(0, len(lines) - 1) * line_spacing
    card_height = text_height + 2 * padding_y
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
        radius=int(style["radius"]),
        fill=(0, 0, 0, 54),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12)))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        rect,
        radius=int(style["radius"]),
        fill=(250, 250, 249, 238),
        outline=(255, 255, 255, 184),
        width=1,
    )
    y = shadow_margin + padding_y - sample_box[1]
    for line in lines:
        line_width = font.getlength(line)
        x = shadow_margin + (requested_width - line_width) / 2
        draw.text((x, y), line, font=font, fill=(24, 24, 26, 255))
        y += line_height + line_spacing

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination)
    return {"width": canvas.width, "height": canvas.height, "lines": len(lines)}
