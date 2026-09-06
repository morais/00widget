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

from PIL import Image

#: The strip the compact Island occupies, as fractions of the capture.
BAND_TOP = 0.015
BAND_BOTTOM = 0.075

#: A tinted glyph: strongly red, mid green, weak blue. The launch fixture's
#: orange sits well inside this; so does every other kind tint the samples use.
def _is_tinted(pixel: tuple[int, int, int]) -> bool:
    red, green, blue = pixel
    return red > 170 and 60 < green < 200 and blue < 110


#: Measured on real captures: 14 points wide when whole, 9 when clipped.
#: Eleven sits between them with room on both sides.
MIN_GLYPH_POINTS = 11.0

#: Captures are 3x on every iPhone this runs against.
SCALE = 3.0


def glyph_width_points(path: Path) -> float | None:
    """The width of the Island's leading glyph, or None if there is no glyph."""
    with Image.open(path) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        pixels = rgb.load()

        # The leading region is left of centre; the trailing content (a ring in
        # the same tint) is right of it and must not be measured with it.
        xs = [
            x
            for y in range(int(height * BAND_TOP), int(height * BAND_BOTTOM), 2)
            for x in range(int(width * 0.25), width // 2, 2)
            if _is_tinted(pixels[x, y])
        ]
        if not xs:
            return None
        return (max(xs) - min(xs)) / SCALE


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
