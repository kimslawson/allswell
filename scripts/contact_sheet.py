#!/usr/bin/env python3
"""Contact sheet of the app icons at their NATIVE pixel sizes — 16px renders
as 16px, 1024px as 1024px — so you can compare how the artwork holds up at
each real size. Finder/Quick Look/Preview all normalize to a uniform grid,
which is the opposite of what we want here.

Icons are laid out left to right, smallest to largest, sharing a common
bottom baseline. Output: <appiconset>/contact_sheet.png (git-ignored-friendly,
just regenerate it).

Usage: python3 scripts/contact_sheet.py [output.png]
Requires: pillow
"""

import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ICON_DIR = os.path.join(os.path.dirname(__file__), "..",
                        "AllsWell", "Assets.xcassets", "AppIcon.appiconset")

PAD = 20          # outer margin
GAP = 28          # horizontal space between icons
LABEL_H = 26      # top strip for size labels
LABEL_GAP = 10    # between label strip and the tallest icon
BG = (228, 228, 230, 255)
LABEL_COLOR = (90, 90, 96, 255)


def load_icons():
    paths = glob.glob(os.path.join(ICON_DIR, "icon_*.png"))
    icons = [(Image.open(p).convert("RGBA"), p) for p in paths]
    icons.sort(key=lambda pair: pair[0].width)
    return icons


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ICON_DIR, "contact_sheet.png")
    icons = load_icons()
    if not icons:
        print(f"No icon_*.png found in {os.path.normpath(ICON_DIR)}")
        return

    tallest = max(im.height for im, _ in icons)
    total_w = PAD * 2 + sum(im.width for im, _ in icons) + GAP * (len(icons) - 1)
    total_h = PAD * 2 + LABEL_H + LABEL_GAP + tallest

    sheet = Image.new("RGBA", (total_w, total_h), BG)
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.load_default(size=18)  # Pillow >= 10 scalable default
    except TypeError:
        font = ImageFont.load_default()

    baseline = total_h - PAD  # all icons sit on this bottom line
    x = PAD
    for im, path in icons:
        sheet.alpha_composite(im, (x, baseline - im.height))
        label = f"{im.width}px"
        bbox = draw.textbbox((0, 0), label, font=font)
        tw = bbox[2] - bbox[0]
        draw.text((x + im.width / 2 - tw / 2, PAD), label, fill=LABEL_COLOR, font=font)
        x += im.width + GAP

    sheet.save(out)
    print(f"Wrote {os.path.normpath(out)} ({total_w}x{total_h})")


if __name__ == "__main__":
    main()
