#!/usr/bin/env python3
"""Refuse a hero capture whose Dynamic Island content is cut off.

The compact Island sometimes draws its leading glyph and trailing content
clipped on their leading edges, with the pill around them at full width. It is
stable within a capture run and varies between runs of identical code, so a
capture can be right one minute and wrong the next, and nothing else in the
pipeline can see the difference: the manifest checks filenames, checksums and
dimensions, and a clipped glyph is none of those.

The cause is not established. Measured and ruled out: the Home Screen page, the
status bar contents, elapsed time, and waiting for the screen to stop changing.
An erased device produced a clean capture and then a clipped one on its very
next run, so it is device state that accumulates within a run rather than
anything in the widget code — the same build draws both.

What is established is how to tell them apart. The activity's glyph is a filled
SF Symbol in the kind's tint, and when it is clipped it loses its leading third:
measured at 13 points wide when whole and 8 when cut, on the same capture device
at the same scale. That gap is wide enough to test.

This is deliberately a check rather than a fix. It cannot stop the Island being
drawn wrong; it stops a wrong one becoming an App Store screenshot, and turns an
unpredictable defect into a re-run.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageOps

#: The leading compact region in portrait. Landscape captures carry an EXIF
#: orientation and put the width-limited Island vertically down the left edge,
#: so they use a separate crop after ImageOps.exif_transpose normalises them.
PORTRAIT_BOUNDS = (0.20, 0.015, 0.40, 0.075)
LANDSCAPE_BOUNDS = (0.01, 0.20, 0.08, 0.35)

#: A strongly saturated launch glyph. The waiting phase is orange and the
#: completed phase is green; accepting both lets the same geometric check guard
#: the App Store hero and the website's 5/5 payoff without confusing white
#: status-bar content for the glyph.
def _is_tinted(pixel: tuple[int, int, int]) -> bool:
    red, green, blue = pixel
    orange = red > 170 and 60 < green < 200 and blue < 110
    green = green > 150 and red < 130 and blue < 150
    return orange or green


def _is_activity_foreground(pixel: tuple[int, int, int]) -> bool:
    """Tinted or neutral content drawn inside the black Island capsule."""
    if _is_tinted(pixel):
        return True
    red, green, blue = pixel
    return max(red, green, blue) - min(red, green, blue) < 20 and 80 < max(
        red, green, blue
    ) < 250


def _component_widths(mask: set[tuple[int, int]]) -> list[int]:
    """Widths of plausible glyph components, excluding the capsule edge."""
    widths: list[int] = []
    bounds: list[tuple[int, int, int, int]] = []
    while mask:
        seed = mask.pop()
        stack = [seed]
        min_x = max_x = seed[0]
        min_y = max_y = seed[1]
        area = 1
        while stack:
            x, y = stack.pop()
            for neighbour_y in range(y - 1, y + 2):
                for neighbour_x in range(x - 1, x + 2):
                    neighbour = (neighbour_x, neighbour_y)
                    if neighbour not in mask:
                        continue
                    mask.remove(neighbour)
                    stack.append(neighbour)
                    min_x = min(min_x, neighbour_x)
                    max_x = max(max_x, neighbour_x)
                    min_y = min(min_y, neighbour_y)
                    max_y = max(max_y, neighbour_y)
                    area += 1

        component_width = max_x - min_x + 1
        component_height = max_y - min_y + 1
        # A compact glyph is roughly 14pt square. The capsule's antialiased
        # outline is long in one axis, while wallpaper noise is tiny.
        if (
            area >= 20
            and 3 * SCALE <= component_width <= 30 * SCALE
            and 3 * SCALE <= component_height <= 30 * SCALE
        ):
            widths.append(component_width)
            bounds.append((min_x, min_y, max_x, max_y))

    # Outline symbols such as timer can be split into several disconnected
    # strokes. Treat nearby strokes as one glyph, while retaining the per-part
    # widths above in case unrelated foreground also entered the crop.
    if bounds:
        union_width = max(bound[2] for bound in bounds) - min(
            bound[0] for bound in bounds
        ) + 1
        union_height = max(bound[3] for bound in bounds) - min(
            bound[1] for bound in bounds
        ) + 1
        if union_width <= 30 * SCALE and union_height <= 30 * SCALE:
            widths.append(union_width)
    return widths


#: Measured on real captures: 14 points wide when whole, 9 when clipped.
#: Eleven sits between them with room on both sides.
MIN_GLYPH_POINTS = 11.0

#: Captures are 3x on every iPhone this runs against.
SCALE = 3.0


def glyph_width_points(path: Path) -> float | None:
    """The width of the Island's leading glyph, or None if there is no glyph."""
    with Image.open(path) as image:
        rgb = ImageOps.exif_transpose(image).convert("RGB")
        width, height = rgb.size
        pixels = rgb.load()

        if width >= height:
            left, top, right, bottom = LANDSCAPE_BOUNDS
        else:
            left, top, right, bottom = PORTRAIT_BOUNDS

        # The leading region is left of centre; the trailing content (a ring in
        # the same tint) is outside this crop and must not be measured with it.
        # Neutral foreground is needed for countdown and item-count fixtures,
        # whose system presentation is grey rather than the app's accent tint.
        tinted_xs = [
            x
            for y in range(int(height * top), int(height * bottom))
            for x in range(int(width * left), int(width * right))
            if _is_tinted(pixels[x, y])
        ]
        if tinted_xs:
            return (max(tinted_xs) - min(tinted_xs) + 1) / SCALE

        mask = {
            (x, y)
            for y in range(int(height * top), int(height * bottom))
            for x in range(int(width * left), int(width * right))
            if _is_activity_foreground(pixels[x, y])
        }
        component_widths = _component_widths(mask)
        if not component_widths:
            return None
        return max(component_widths) / SCALE


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: island_check.py <hero-capture.png>")
    path = Path(sys.argv[1])
    measured = glyph_width_points(path)
    if measured is None:
        raise SystemExit(
            f"no Dynamic Island glyph found in {path.name} — the activity may "
            "not have been presenting when the capture was taken"
        )
    if measured < MIN_GLYPH_POINTS:
        raise SystemExit(
            f"the Dynamic Island's glyph is {measured:.0f} points wide in "
            f"{path.name}, against {MIN_GLYPH_POINTS:.0f} expected: its "
            "content is clipped. Re-run the capture — this varies between "
            "runs of identical code."
        )
    print(f"  Dynamic Island glyph {measured:.0f}pt — not clipped")


if __name__ == "__main__":
    main()
