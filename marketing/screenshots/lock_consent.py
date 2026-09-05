#!/usr/bin/env python3
"""Find iOS's Live Activities consent prompt in a Lock Screen capture.

The first Live Activity an app presents on a Lock Screen raises "Allow Live
Activities from <app>?", and a later one raises "Do you want to continue to
allow…". Both are drawn *inside* the activity's own presentation, so both land
in the framebuffer `simctl io screenshot` captures — and an App Store
screenshot may not contain a system permission prompt.

There is no way to pre-answer it. `simctl privacy` has no ActivityKit service
and granting `all` changes nothing; the prompt is never presented while the
device is unlocked, so XCUITest never sees it; and a locked device takes no
XCUITest input at all. What is left is to answer it the way a person would,
which means finding its button.

**The signal is the buttons' own text.** Three cheaper ideas were tried
against the three real captures and each failed on one of them:

- an absolute darkness threshold — the activity's panel is translucent, so it
  measured 46 over a pale wallpaper and 17 over a dark navy one, against the
  consent panel's 9-22 and 0-1. Any fixed cut separating one pair put the tap
  *inside the card* on the other, and a tap there opens the app;
- the darkest band — a capture holds short strips of true black elsewhere;
- the tallest dark band — on a dark wallpaper the region below the card is
  taller than the panel and every bit as dark.

Bright text on a near-black panel is what none of those have. The panel's two
buttons are the only place on a Lock Screen where bright glyphs sit in two
horizontally separated groups inside a dark band, so the tap point is read off
the label itself rather than guessed as a fraction of a box.
"""

from __future__ import annotations

import statistics
import sys
from pathlib import Path

from PIL import Image

#: Rows below this fraction of the height are where an activity is drawn.
SEARCH_TOP = 0.40

#: How much lighter than the darkest row a row may be and still belong to the
#: same panel. Relative, because both the panel and the card move with the
#: wallpaper behind them.
DARK_TOLERANCE = 15

#: The consent panel is a question and two buttons.
MIN_HEIGHT_FRACTION = 0.03

#: A glyph, against a panel that is nearly black.
BRIGHT = 170

#: The gap between "Don't Allow" and "Allow", as a fraction of the width.
MIN_GAP_FRACTION = 0.06

#: Enough lit pixels to be words rather than a speck of noise.
MIN_BRIGHT_PIXELS = 150

#: Vertical gap, as a fraction of the height, that separates one line of text
#: from the next.
MIN_LINE_GAP = 0.008


def _row_median(pixels, width: int, y: int) -> float:
    return statistics.median(
        pixels[x, y] for x in range(int(width * 0.2), int(width * 0.8), 8)
    )


def _dark_bands(rows: dict[int, float], cutoff: float) -> list[tuple[int, int]]:
    bands: list[tuple[int, int]] = []
    start: int | None = None
    ordered = sorted(rows)
    for y in ordered:
        if rows[y] <= cutoff:
            if start is None:
                start = y
        elif start is not None:
            bands.append((start, y))
            start = None
    if start is not None:
        bands.append((start, ordered[-1]))
    return bands


def _clusters(xs: list[int], gap: int) -> list[tuple[int, int]]:
    """Contiguous groups of x positions, split wherever a gap exceeds `gap`."""
    if not xs:
        return []
    groups: list[tuple[int, int]] = []
    start = previous = xs[0]
    for x in xs[1:]:
        if x - previous > gap:
            groups.append((start, previous))
            start = x
        previous = x
    groups.append((start, previous))
    return groups


def find_allow_button(path: Path) -> tuple[int, int] | None:
    """The affirmative button's centre in device pixels, or None if no prompt."""
    with Image.open(path) as image:
        grey = image.convert("L")
        width, height = grey.size
        pixels = grey.load()

        rows = {
            y: _row_median(pixels, width, y)
            for y in range(int(height * SEARCH_TOP), height)
        }
        if not rows:
            return None
        cutoff = min(rows.values()) + DARK_TOLERANCE

        for top, bottom in _dark_bands(rows, cutoff):
            if (bottom - top) < height * MIN_HEIGHT_FRACTION:
                continue

            # The buttons sit below the question, so read the lower half of
            # the band: a one-line question and a two-line one both leave them
            # there.
            lit: list[tuple[int, int]] = []
            for y in range((top + bottom) // 2, bottom, 2):
                for x in range(0, width, 2):
                    if pixels[x, y] >= BRIGHT:
                        lit.append((x, y))
            if len(lit) < MIN_BRIGHT_PIXELS:
                continue

            groups = _clusters(
                sorted({x for x, _ in lit}), round(width * MIN_GAP_FRACTION)
            )
            if len(groups) != 2:
                continue

            # …and on one line. The buttons are a single row of text with
            # nothing under them, while the lower half of an activity's card
            # holds several rows — an item and its reading, then the "+2 more"
            # line — which are also two bright clusters with a gap between
            # them. Without this the detector aimed a click at a card on a
            # clean capture, and the click opened the app.
            lines = _clusters(sorted({y for _, y in lit}), round(height * MIN_LINE_GAP))
            if len(lines) != 1:
                continue

            left, right = groups[1]
            ys = [y for x, y in lit if left <= x <= right]
            return ((left + right) // 2, (min(ys) + max(ys)) // 2)

        return None


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: lock_consent.py <capture.png>")
    found = find_allow_button(Path(sys.argv[1]))
    print("none" if found is None else f"{found[0]} {found[1]}")


if __name__ == "__main__":
    main()
