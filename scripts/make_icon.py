#!/usr/bin/env python3
"""Generates the AllsWell app icon: a classic Aqua-style image well (recessed,
bordered, rounded rect on the modern macOS icon grid) containing a generic
image-file icon. Writes all AppIcon.appiconset PNGs plus Contents.json.

Usage: python3 scripts/make_icon.py
Requires: pillow
"""

import json
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024
MARGIN = 100               # modern macOS icon grid: artwork inset from canvas
RADIUS = 185               # ~22.4% of the 824px artwork, matches system icons
BOX = (MARGIN, MARGIN, S - MARGIN, S - MARGIN)

OUT_DIR = os.path.join(os.path.dirname(__file__), "..",
                       "AllsWell", "Assets.xcassets", "AppIcon.appiconset")


def rounded_mask(box, radius, blur=0):
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    if blur:
        mask = mask.filter(ImageFilter.GaussianBlur(blur))
    return mask


def make_well():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = rounded_mask(BOX, RADIUS)

    # Vertical gradient fill: slightly darker at the top (recessed look).
    grad = Image.new("L", (1, 256))
    for y in range(256):
        grad.putpixel((0, y), int(229 + (250 - 229) * y / 255))
    grad = grad.resize((S, S))
    fill = Image.merge("RGBA", (grad, grad,
                                grad.point(lambda v: min(255, v + 3)),
                                Image.new("L", (S, S), 255)))
    icon.paste(fill, (0, 0), mask)

    # Inner shadow: band along the top edge, clipped to the well.
    top_band = ImageChops.subtract(
        rounded_mask(BOX, RADIUS),
        rounded_mask((BOX[0], BOX[1] + 34, BOX[2], BOX[3] + 34), RADIUS))
    top_band = top_band.filter(ImageFilter.GaussianBlur(20))
    top_band = ImageChops.multiply(top_band, mask)
    icon.paste(Image.new("RGBA", (S, S), (35, 35, 45, 255)), (0, 0),
               top_band.point(lambda v: int(v * 0.42)))

    # Faint all-around inset shading so the sides read as recessed too.
    ring = ImageChops.subtract(
        rounded_mask(BOX, RADIUS),
        rounded_mask((BOX[0] + 22, BOX[1] + 22, BOX[2] - 22, BOX[3] - 22),
                     RADIUS - 22))
    ring = ring.filter(ImageFilter.GaussianBlur(14))
    ring = ImageChops.multiply(ring, mask)
    icon.paste(Image.new("RGBA", (S, S), (40, 40, 50, 255)), (0, 0),
               ring.point(lambda v: int(v * 0.16)))

    # Bottom inner highlight, the classic Aqua glint.
    bottom_band = ImageChops.subtract(
        rounded_mask(BOX, RADIUS),
        rounded_mask((BOX[0], BOX[1] - 26, BOX[2], BOX[3] - 26), RADIUS))
    bottom_band = bottom_band.filter(ImageFilter.GaussianBlur(14))
    bottom_band = ImageChops.multiply(bottom_band, mask)
    icon.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0),
               bottom_band.point(lambda v: int(v * 0.75)))

    # The border that makes it legible as a well.
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle(BOX, radius=RADIUS, outline=(125, 125, 132, 255),
                           width=13)
    inner = (BOX[0] + 13, BOX[1] + 13, BOX[2] - 13, BOX[3] - 13)
    draw.rounded_rectangle(inner, radius=RADIUS - 13,
                           outline=(90, 90, 98, 90), width=4)
    return icon


def draw_page(icon, photo=None):
    """Generic image-file icon: white page, dog-eared corner, photo inside.
    With `photo`, that image fills the photo area instead of the abstract
    sky/sun/hills artwork."""
    page_w, page_h, fold = 380, 470, 96
    x0 = (S - page_w) // 2
    y0 = (S - page_h) // 2 + 6
    x1, y1 = x0 + page_w, y0 + page_h

    # Soft drop shadow under the page, following the dog-eared outline.
    shadow = Image.new("L", (S, S), 0)
    shadow_page = [(x, y + 12) for x, y in
                   [(x0, y0), (x1 - fold, y0), (x1, y0 + fold),
                    (x1, y1), (x0, y1)]]
    ImageDraw.Draw(shadow).polygon(shadow_page, fill=255)
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))
    shadow = ImageChops.multiply(shadow, rounded_mask(BOX, RADIUS))
    icon.paste(Image.new("RGBA", (S, S), (30, 30, 40, 255)), (0, 0),
               shadow.point(lambda v: int(v * 0.30)))

    draw = ImageDraw.Draw(icon)
    page = [(x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)]
    draw.polygon(page, fill=(255, 255, 255, 255), outline=(140, 140, 148, 255))
    draw.line(page + [page[0]], fill=(140, 140, 148, 255), width=7, joint="curve")

    # Dog-ear fold.
    draw.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)],
                 fill=(216, 216, 222, 255), outline=(140, 140, 148, 255))
    draw.line([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)],
              fill=(140, 140, 148, 255), width=6, joint="curve")

    # Photo area.
    px0, py0 = x0 + 42, y0 + 130
    px1, py1 = x1 - 42, y1 - 48

    if photo is not None:
        # Center-crop the photo to the frame's aspect and drop it in.
        frame_w, frame_h = px1 - px0, py1 - py0
        scale = max(frame_w / photo.width, frame_h / photo.height)
        resized = photo.convert("RGB").resize(
            (round(photo.width * scale), round(photo.height * scale)),
            Image.LANCZOS)
        cx = (resized.width - frame_w) // 2
        cy = (resized.height - frame_h) // 2
        icon.paste(resized.crop((cx, cy, cx + frame_w, cy + frame_h)),
                   (px0, py0))
        ImageDraw.Draw(icon).rectangle((px0, py0, px1, py1),
                                       outline=(150, 150, 158, 255), width=5)
        return icon

    # Abstract artwork: sky, sun, hills.
    sky = Image.new("RGBA", (px1 - px0, py1 - py0))
    for y in range(sky.height):
        t = y / max(1, sky.height - 1)
        sky.putpixel((0, y), (int(108 + t * 96), int(176 + t * 56),
                              int(236 + t * 14), 255))
    sky = sky.resize((px1 - px0, py1 - py0))
    for y in range(sky.height):
        c = sky.getpixel((0, y))
        ImageDraw.Draw(sky).line([(0, y), (sky.width, y)], fill=c)
    icon.paste(sky, (px0, py0))

    pdraw = ImageDraw.Draw(icon)
    # Sun.
    sun_r = 46
    sun_c = (px1 - 78, py0 + 84)
    pdraw.ellipse((sun_c[0] - sun_r, sun_c[1] - sun_r,
                   sun_c[0] + sun_r, sun_c[1] + sun_r),
                  fill=(255, 211, 75, 255))
    # Hills: clip to the photo rect by drawing into an overlay.
    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)
    w = px1 - px0
    odraw.polygon([(px0 - 10, py1), (px0 + int(w * 0.38), py0 + int((py1 - py0) * 0.42)),
                   (px0 + int(w * 0.78), py1)], fill=(106, 160, 88, 255))
    odraw.polygon([(px0 + int(w * 0.42), py1), (px0 + int(w * 0.80), py0 + int((py1 - py0) * 0.55)),
                   (px1 + 10, py1)], fill=(136, 188, 110, 255))
    photo_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(photo_mask).rectangle((px0, py0, px1, py1), fill=255)
    icon.paste(overlay, (0, 0), ImageChops.multiply(overlay.split()[3], photo_mask))
    # Photo border.
    pdraw.rectangle((px0, py0, px1, py1), outline=(150, 150, 158, 255), width=5)
    return icon


SIZES = [
    ("icon_16.png", 16, "16x16", "1x"),
    ("icon_32.png", 32, "16x16", "2x"),
    ("icon_32.png", 32, "32x32", "1x"),
    ("icon_64.png", 64, "32x32", "2x"),
    ("icon_128.png", 128, "128x128", "1x"),
    ("icon_256.png", 256, "128x128", "2x"),
    ("icon_256.png", 256, "256x256", "1x"),
    ("icon_512.png", 512, "256x256", "2x"),
    ("icon_512.png", 512, "512x512", "1x"),
    ("icon_1024.png", 1024, "512x512", "2x"),
]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    icon = draw_page(make_well())

    written = set()
    for filename, px, _, _ in SIZES:
        if filename in written:
            continue
        written.add(filename)
        scaled = icon if px == S else icon.resize((px, px), Image.LANCZOS)
        scaled.save(os.path.join(OUT_DIR, filename))

    contents = {
        "images": [
            {"filename": f, "idiom": "mac", "scale": scale, "size": size}
            for f, _, size, scale in SIZES
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(OUT_DIR, "Contents.json"), "w") as fp:
        json.dump(contents, fp, indent=2)
        fp.write("\n")
    print(f"Wrote {len(written)} icon sizes to {os.path.normpath(OUT_DIR)}")

    make_lena_variant()


def make_lena_variant():
    """Easter-egg Dock icon: the well holds Lena instead of the abstract art.
    Generated only if lena_std.tif is present in the repo root."""
    lena_path = os.path.join(os.path.dirname(__file__), "..", "lena_std.tif")
    if not os.path.exists(lena_path):
        print("lena_std.tif not found; skipping easter-egg icon")
        return
    out_dir = os.path.join(os.path.dirname(OUT_DIR), "LenaIcon.imageset")
    os.makedirs(out_dir, exist_ok=True)
    icon = draw_page(make_well(), photo=Image.open(lena_path))
    icon.save(os.path.join(out_dir, "lena_icon.png"))
    contents = {
        "images": [
            {"filename": "lena_icon.png", "idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(out_dir, "Contents.json"), "w") as fp:
        json.dump(contents, fp, indent=2)
        fp.write("\n")
    print(f"Wrote easter-egg icon to {os.path.normpath(out_dir)}")


if __name__ == "__main__":
    main()
