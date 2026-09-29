#!/usr/bin/env python3
"""Frame one Spatial Simulator capture as a 2560x1440 (16:9) store screenshot.

    compose_store_shot.py RAW OUT WINDOW_TOP WINDOW_BOTTOM

The simulator's display is 2064x2208, too narrow for a 16:9 frame that
keeps a margin around a panel, and `wm size` only letterboxes it. So the
panel's full-width band (the window plus a margin, in screen pixels) stays
sharp in the middle, and the frame is widened to 16:9 with a blurred,
slightly darkened copy of the same band behind it, feathered at the seam.
The result is scaled to exactly 2560x1440. Needs Pillow.
"""
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

OUT_W, OUT_H = 2560, 1440
MARGIN = 60  # screen pixels of room kept above and below the window
FEATHER = 90  # width of the blend between the sharp band and the blur
BLUR = 40
DIM = 0.8


def main() -> None:
    raw_path, out_path, win_top, win_bottom = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    raw = Image.open(raw_path).convert("RGB")
    w, h = raw.size

    # The band: the window plus a margin, at least as tall as a full-width
    # 16:9 frame needs, centred on the window and kept inside the capture.
    band_h = min(h, max(win_bottom - win_top + 2 * MARGIN, w * OUT_H // OUT_W))
    top = (win_top + win_bottom) // 2 - band_h // 2
    top = max(0, min(top, h - band_h))
    band = raw.crop((0, top, w, top + band_h))

    canvas_w = band_h * OUT_W // OUT_H
    if canvas_w <= w:
        # Wide enough already: a plain centred crop.
        left = (w - canvas_w) // 2
        framed = band.crop((left, 0, left + canvas_w, band_h))
    else:
        backdrop = band.resize((canvas_w, canvas_w * band_h // w), Image.LANCZOS)
        backdrop = backdrop.crop((0, (backdrop.height - band_h) // 2, canvas_w, (backdrop.height - band_h) // 2 + band_h))
        backdrop = ImageEnhance.Brightness(backdrop.filter(ImageFilter.GaussianBlur(BLUR))).enhance(DIM)

        mask = Image.new("L", (w, band_h), 255)
        draw = ImageDraw.Draw(mask)
        for x in range(FEATHER):
            alpha = int(255 * x / FEATHER)
            draw.line([(x, 0), (x, band_h)], fill=alpha)
            draw.line([(w - 1 - x, 0), (w - 1 - x, band_h)], fill=alpha)
        backdrop.paste(band, ((canvas_w - w) // 2, 0), mask)
        framed = backdrop

    framed.resize((OUT_W, OUT_H), Image.LANCZOS).save(out_path, "PNG")


if __name__ == "__main__":
    main()
