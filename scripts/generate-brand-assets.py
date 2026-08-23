#!/usr/bin/env python3
"""Generate 00Widget assets from the approved U2 identity sheet."""

from __future__ import annotations

from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[1]
BRAND_DIR = REPO_ROOT / "docs" / "brand"
SOURCE = BRAND_DIR / "branding-sheet.png"
MARK_MASTER = BRAND_DIR / "mark-transparent-master.png"
APP_ICON_MASTER = BRAND_DIR / "app-icon-master.png"

NAVY = "#06152A"
MID_NAVY = "#4C607D"
WHITE = "#F8FBFF"
GRAY = "#A9B7CC"
FONT_PATH = "/System/Library/Fonts/Avenir Next.ttc"

# Pixel-exact regions from the approved 1536 × 1024 U2 identity sheet.
MARK_BOX = (100, 50, 630, 570)
APP_ICON_BOX = (105, 685, 375, 955)
WORDMARK_BOX = (675, 225, 1475, 505)


def font(size: int, *, index: int = 5) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, size=size, index=index)


def crop(box: tuple[int, int, int, int]) -> Image.Image:
    return Image.open(SOURCE).convert("RGBA").crop(box)


def isolate_mark(image: Image.Image, *, seal: int = 10, floor: int = 25, ceiling: int = 70) -> Image.Image:
    """Cut the approved master's navy backdrop away without touching the art.

    The backdrop is a gradient, so a pixel counts as backdrop by *distance* from
    the corner colour rather than by an exact match, and only pixels connected
    to the image edge are removed: the mark's own navy hat band, card outline,
    and eye glyphs sit well inside that same distance and have to survive.

    Connectivity alone is not enough, because the card outline touches the
    backdrop through a hairline where the brim crosses it — enough for an
    unsealed fill to drain the entire outline. Closing the art mask by `seal`
    pixels bridges that hairline first. The close feeds connectivity only;
    alpha still comes from each pixel's own distance, which keeps the cut edge
    anti-aliased instead of stair-stepped.
    """
    rgba = image.convert("RGBA")
    width, height = rgba.size
    pixels = rgba.load()
    corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    backdrop = tuple(round(sum(pixels[x, y][channel] for x, y in corners) / 4) for channel in range(3))

    raw = rgba.tobytes()
    distances = [
        (
            (raw[offset] - backdrop[0]) ** 2
            + (raw[offset + 1] - backdrop[1]) ** 2
            + (raw[offset + 2] - backdrop[2]) ** 2
        )
        ** 0.5
        for offset in range(0, len(raw), 4)
    ]

    art = Image.new("L", (width, height))
    art.putdata([255 if distance > ceiling else 0 for distance in distances])
    kernel = seal * 2 + 1
    sealed = art.filter(ImageFilter.MaxFilter(kernel)).filter(ImageFilter.MinFilter(kernel)).load()

    queue: deque[tuple[int, int]] = deque()
    outside = bytearray(width * height)
    for x in range(width):
        queue.append((x, 0))
        queue.append((x, height - 1))
    for y in range(height):
        queue.append((0, y))
        queue.append((width - 1, y))

    while queue:
        x, y = queue.popleft()
        index = y * width + x
        if outside[index] or sealed[x, y]:
            continue
        outside[index] = 1
        if x:
            queue.append((x - 1, y))
        if x + 1 < width:
            queue.append((x + 1, y))
        if y:
            queue.append((x, y - 1))
        if y + 1 < height:
            queue.append((x, y + 1))

    alpha = bytearray(width * height)
    for index, distance in enumerate(distances):
        if not outside[index]:
            alpha[index] = 255
        elif distance > floor:
            alpha[index] = min(255, round((distance - floor) * 255 / (ceiling - floor)))
    rgba.putalpha(Image.frombytes("L", (width, height), bytes(alpha)))
    return rgba


def remove_light_background(image: Image.Image) -> Image.Image:
    """Remove the identity sheet's light backdrop from text-only artwork."""
    rgba = image.convert("RGBA")
    result: list[tuple[int, int, int, int]] = []
    for red, green, blue, _ in rgba.getdata():
        distance = ((red - 249) ** 2 + (green - 249) ** 2 + (blue - 249) ** 2) ** 0.5
        alpha = max(0, min(255, round((distance - 2) * 255 / 28)))
        result.append((red, green, blue, alpha))
    rgba.putdata(result)
    return rgba


def contain(image: Image.Image, size: tuple[int, int], padding: int = 0) -> Image.Image:
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    available = (size[0] - padding * 2, size[1] - padding * 2)
    fitted = ImageOps.contain(image, available, Image.Resampling.LANCZOS)
    canvas.alpha_composite(fitted, ((size[0] - fitted.width) // 2, (size[1] - fitted.height) // 2))
    return canvas


def dark_background(size: tuple[int, int]) -> Image.Image:
    gradient = Image.radial_gradient("L").resize(size, Image.Resampling.LANCZOS)
    return ImageOps.colorize(gradient, black=NAVY, white="#153B73").convert("RGBA")


def save(image: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        image = image.convert("RGB")
    image.save(path, optimize=True)


def exact_wordmark(*, transparent: bool) -> Image.Image:
    source = crop(WORDMARK_BOX)
    if transparent:
        source = remove_light_background(source)
    return source.resize((2400, 840), Image.Resampling.LANCZOS)


def clean_wordmark(size: tuple[int, int], *, dark_surface: bool) -> Image.Image:
    """Re-typeset the approved lockup cleanly for transparent/dark contexts."""
    width, height = size
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    title_font = font(round(height * 0.45), index=9)
    tagline_font = font(round(height * 0.145), index=5)
    title_y = round(height * 0.04)
    zero_x = round(width * 0.02)
    zero_mask = Image.new("L", size, 0)
    ImageDraw.Draw(zero_mask).text((zero_x, title_y), "00", font=title_font, fill=255)
    blue_gradient = Image.new("RGBA", size, "#0874F7")
    image.paste(blue_gradient, (0, 0), zero_mask)
    zero_width = draw.textlength("00", font=title_font)
    widget_x = round(zero_x + zero_width + height * 0.025)
    draw.text((widget_x, title_y), "Widget", font=title_font, fill=WHITE if dark_surface else NAVY)
    draw.text(
        (round(width * 0.04), round(height * 0.62)),
        "Widgets for all your agents.",
        font=tagline_font,
        fill=GRAY if dark_surface else MID_NAVY,
    )
    return image


def tv_hero(mark: Image.Image, size: tuple[int, int]) -> Image.Image:
    width, height = size
    image = dark_background(size)
    mark_size = round(height * 0.82)
    image.alpha_composite(contain(mark, (mark_size, mark_size)), (round(width * 0.055), (height - mark_size) // 2))
    wordmark = clean_wordmark((1200, 420), dark_surface=True)
    target_width = round(width * 0.55)
    target_height = round(target_width * wordmark.height / wordmark.width)
    wordmark = wordmark.resize((target_width, target_height), Image.Resampling.LANCZOS)
    image.alpha_composite(wordmark, (round(width * 0.40), (height - target_height) // 2))
    return image


def launch(mark: Image.Image) -> Image.Image:
    image = dark_background((1920, 1080))
    image.alpha_composite(contain(mark, (700, 700)), (115, 190))
    wordmark = clean_wordmark((950, 333), dark_surface=True)
    image.alpha_composite(wordmark, (830, 360))
    return image


def branding_sheet(mark: Image.Image, app_icon: Image.Image, wordmark: Image.Image) -> Image.Image:
    image = Image.new("RGBA", (1536, 1024), "#F5F7FA")
    draw = ImageDraw.Draw(image)
    draw.text((70, 50), "00Widget identity system", font=font(42, index=0), fill=NAVY)
    draw.text((70, 108), "U2 — approved master", font=font(24), fill=MID_NAVY)
    image.alpha_composite(contain(mark, (520, 520)), (35, 135))
    image.alpha_composite(ImageOps.contain(wordmark, (830, 290), Image.Resampling.LANCZOS), (620, 220))
    draw.line((70, 640, 1466, 640), fill="#D8E0EA", width=2)
    draw.rounded_rectangle((70, 690, 340, 960), radius=50, fill="#FFFFFF", outline="#D8E0EA")
    image.alpha_composite(app_icon.resize((250, 250), Image.Resampling.LANCZOS), (80, 700))
    draw.text((425, 735), "Two cards", font=font(30, index=0), fill=NAVY)
    draw.text((425, 788), "A secret agent for every widget.", font=font(25), fill=MID_NAVY)
    draw.text((425, 850), "Widgets for all your agents.", font=font(31, index=0), fill=NAVY)
    return image


def resize(source: Image.Image, size: tuple[int, int], *, opaque: bool = False) -> Image.Image:
    result = source.resize(size, Image.Resampling.LANCZOS)
    return result.convert("RGB") if opaque else result


def generate() -> None:
    for required in (SOURCE, APP_ICON_MASTER):
        if not required.exists():
            raise SystemExit(f"Missing approved identity source: {required}")

    app_icon_master = Image.open(APP_ICON_MASTER).convert("RGB")
    mark = isolate_mark(app_icon_master)
    app_icon = app_icon_master.resize((1024, 1024), Image.Resampling.LANCZOS)
    wordmark_opaque = exact_wordmark(transparent=False).convert("RGB")
    wordmark_transparent = clean_wordmark((2400, 840), dark_surface=True)

    save(mark, MARK_MASTER)
    save(app_icon, BRAND_DIR / "mark-1024.png", opaque=True)
    save(contain(mark, (1024, 1024), padding=20), BRAND_DIR / "mark-transparent-1024.png")
    save(resize(app_icon_master, (512, 512), opaque=True), BRAND_DIR / "plugin-logo.png", opaque=True)
    save(contain(mark, (512, 512), padding=10), BRAND_DIR / "plugin-composer-icon.png")
    save(wordmark_opaque, BRAND_DIR / "wordmark-horizontal.png", opaque=True)
    save(wordmark_transparent, BRAND_DIR / "wordmark-horizontal-transparent.png")

    save(app_icon, REPO_ROOT / "ios/Resources/App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png", opaque=True)
    save(app_icon, REPO_ROOT / "ios/Resources/Clip/Assets.xcassets/AppIcon.appiconset/Icon-1024.png", opaque=True)

    tv_assets = REPO_ROOT / "ios/Resources/TV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    back_store = dark_background((2560, 1536)).convert("RGB")
    front_store = contain(mark, (2560, 1536), padding=250)
    back_regular = resize(back_store, (800, 480), opaque=True)
    front_regular = resize(front_store, (800, 480))

    save(back_store, tv_assets / "App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/Back@2x.png", opaque=True)
    save(resize(back_store, (1280, 768), opaque=True), tv_assets / "App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/Back.png", opaque=True)
    save(front_store, tv_assets / "App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/Front@2x.png")
    save(resize(front_store, (1280, 768)), tv_assets / "App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/Front.png")
    save(back_regular, tv_assets / "App Icon.imagestack/Back.imagestacklayer/Content.imageset/Back@2x.png", opaque=True)
    save(resize(back_regular, (400, 240), opaque=True), tv_assets / "App Icon.imagestack/Back.imagestacklayer/Content.imageset/Back.png", opaque=True)
    save(front_regular, tv_assets / "App Icon.imagestack/Front.imagestacklayer/Content.imageset/Front@2x.png")
    save(resize(front_regular, (400, 240)), tv_assets / "App Icon.imagestack/Front.imagestacklayer/Content.imageset/Front.png")

    top_shelf = tv_hero(mark, (1920, 720))
    top_shelf_wide = tv_hero(mark, (2320, 720))
    save(resize(top_shelf, (3840, 1440), opaque=True), tv_assets / "Top Shelf Image.imageset/TopShelf@2x.png", opaque=True)
    save(top_shelf, tv_assets / "Top Shelf Image.imageset/TopShelf.png", opaque=True)
    save(resize(top_shelf_wide, (4640, 1440), opaque=True), tv_assets / "Top Shelf Image Wide.imageset/TopShelfWide@2x.png", opaque=True)
    save(top_shelf_wide, tv_assets / "Top Shelf Image Wide.imageset/TopShelfWide.png", opaque=True)
    save(launch(mark), REPO_ROOT / "ios/Resources/TV/Assets.xcassets/LaunchImage.imageset/Launch.png", opaque=True)

if __name__ == "__main__":
    generate()
