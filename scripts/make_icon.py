#!/usr/bin/env python3
"""Generates the AllsWell app icon: a classic Aqua-style image well (recessed,
bordered, rounded rect on the modern macOS icon grid) holding three documents
side by side — audio, image, video — with the outer two clipped by the well's
edges. Writes all AppIcon.appiconset PNGs plus Contents.json.

Optical sizing: rather than downscaling one master to every size (which makes
the well edge and inner shadow vanish below ~64px and turns the three-doc
composition to mush), each size is rendered from a master tuned for it. Small
sizes drop to a single, larger document and get a disproportionately thicker
border and stronger inner shadow — computed backward from the target pixel
size — so the recessed-well read survives the downscale, the way a typeface's
optical-size cut fattens details for small text.

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


def geom(margin):
    """Well bounding box and corner radius for a given canvas margin, keeping
    the ~22.4% corner proportion of the system grid."""
    box = (margin, margin, S - margin, S - margin)
    radius = round((S - 2 * margin) * 0.224)
    return box, radius


def params_for(px):
    """Per-size rendering recipe. Master dimensions for small sizes are scaled
    by k = S/px so that, once downscaled to `px`, edges and shadows land at an
    intended *final* pixel thickness instead of disappearing.

    Three regimes:
      <=32  menu / list sizes: the well fills nearly the whole tile, borderless,
            defined purely by a recessed shadow, with a big single document — so
            it carries the same visual mass as neighbouring icons in a menu.
      ==64  Finder list / medium: an inset Aqua well with a border and a boosted
            recessed shadow, single document.
      >=128 the full three-doc composition, unchanged from the grid version.
    """
    k = S / px
    if px <= 32:
        box, radius = geom(8)
        return dict(minimal=True, box=box, radius=radius,
                    border_w=0, inner_w=0,
                    shadow_opacity=0.68, shadow_band=round(3.2 * k), shadow_blur=1.8 * k,
                    ring_opacity=0.44, ring_inset=round(2.1 * k), ring_blur=1.3 * k,
                    doc_scale=(1.32 if px <= 16 else 1.20))
    if px <= 64:
        box, radius = geom(64)
        return dict(minimal=True, box=box, radius=radius,
                    border_w=round(1.7 * k), inner_w=round(0.6 * k),
                    shadow_opacity=0.72, shadow_band=round(2.8 * k), shadow_blur=1.8 * k,
                    ring_opacity=0.28, ring_inset=22, ring_blur=14,
                    doc_scale=1.06)
    box, radius = geom(100)
    return dict(minimal=False, box=box, radius=radius,
                border_w=13, inner_w=4,
                shadow_opacity=0.55, shadow_band=52, shadow_blur=22,
                ring_opacity=0.22, ring_inset=22, ring_blur=14,
                doc_scale=1.0)


def rounded_mask(box, radius, blur=0):
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=max(1, radius), fill=255)
    if blur:
        mask = mask.filter(ImageFilter.GaussianBlur(blur))
    return mask


def make_well(p):
    box, radius = p["box"], p["radius"]
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = rounded_mask(box, radius)

    # Vertical gradient fill: slightly darker at the top (recessed look).
    grad = Image.new("L", (1, 256))
    for y in range(256):
        grad.putpixel((0, y), int(208 + (232 - 208) * y / 255))
    grad = grad.resize((S, S))
    fill = Image.merge("RGBA", (grad, grad,
                                grad.point(lambda v: min(255, v + 3)),
                                Image.new("L", (S, S), 255)))
    icon.paste(fill, (0, 0), mask)

    # Inner shadow: band along the top edge, clipped to the well. Thickened and
    # darkened for small sizes so it doesn't downscale into nothing — and, when
    # the well is borderless, it is what makes the recess read at all.
    band = max(1, round(p["shadow_band"]))
    top_band = ImageChops.subtract(
        rounded_mask(box, radius),
        rounded_mask((box[0], box[1] + band, box[2], box[3] + band), radius))
    top_band = top_band.filter(ImageFilter.GaussianBlur(max(1, p["shadow_blur"])))
    top_band = ImageChops.multiply(top_band, mask)
    icon.paste(Image.new("RGBA", (S, S), (35, 35, 45, 255)), (0, 0),
               top_band.point(lambda v: int(v * p["shadow_opacity"])))

    # All-around inset shading so the edges read as recessed. For borderless
    # small sizes this is also what gives the well a defined edge, so it's
    # scaled up (thicker inset, stronger) the smaller the icon gets.
    if p["ring_opacity"] > 0:
        inset = max(1, round(p["ring_inset"]))
        ring = ImageChops.subtract(
            rounded_mask(box, radius),
            rounded_mask((box[0] + inset, box[1] + inset,
                          box[2] - inset, box[3] - inset), radius - inset))
        ring = ring.filter(ImageFilter.GaussianBlur(max(1, p["ring_blur"])))
        ring = ImageChops.multiply(ring, mask)
        icon.paste(Image.new("RGBA", (S, S), (40, 40, 50, 255)), (0, 0),
                   ring.point(lambda v: int(v * p["ring_opacity"])))

    # Bottom inner highlight, the classic Aqua glint.
    bottom_band = ImageChops.subtract(
        rounded_mask(box, radius),
        rounded_mask((box[0], box[1] - 26, box[2], box[3] - 26), radius))
    bottom_band = bottom_band.filter(ImageFilter.GaussianBlur(14))
    bottom_band = ImageChops.multiply(bottom_band, mask)
    icon.paste(Image.new("RGBA", (S, S), (255, 255, 255, 255)), (0, 0),
               bottom_band.point(lambda v: int(v * 0.75)))

    draw_border(icon, box, radius, p["border_w"], p["inner_w"])
    return icon


def draw_border(icon, box, radius, border_w=13, inner_w=4):
    """The well's edge stroke. Skipped entirely when border_w is 0 (small
    sizes), where the recessed shadow alone defines the well."""
    if border_w <= 0:
        return
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle(box, radius=radius, outline=(125, 125, 132, 255),
                           width=border_w)
    if inner_w > 0:
        inner = (box[0] + border_w, box[1] + border_w,
                 box[2] - border_w, box[3] - border_w)
        draw.rounded_rectangle(inner, radius=max(1, radius - border_w),
                               outline=(90, 90, 98, 90), width=inner_w)


def draw_docs(icon, p, photo=None):
    """The documents inside the well. Large sizes get three dog-eared pages
    side by side — audio, image, video — with the outer two clipped by the
    well's edges. Small sizes (p["minimal"]) get a single, larger image
    document so something legible survives. With `photo`, that image fills the
    center document instead of the abstract sky/sun/hills artwork."""
    box, radius = p["box"], p["radius"]
    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cy = (S - 470) // 2 + 6 + 470 // 2
    if p["minimal"]:
        draw_doc(overlay, S // 2, cy, p["doc_scale"], "image", photo=photo)
    else:
        draw_doc(overlay, 186, cy, 0.80, "audio")
        draw_doc(overlay, S - 186, cy, 0.80, "video")
        draw_doc(overlay, S // 2, cy, 1.0, "image", photo=photo)

    # Clip everything to the inside of the well border.
    bw = p["border_w"]
    inner = (box[0] + bw, box[1] + bw, box[2] - bw, box[3] - bw)
    clip = rounded_mask(inner, radius - bw)
    icon.paste(overlay, (0, 0), ImageChops.multiply(overlay.split()[3], clip))
    draw_border(icon, box, radius, bw, p["inner_w"])
    return icon


def draw_doc(layer, cx, cy, scale, kind, photo=None):
    """One white page with a dog-eared corner, centered at (cx, cy), holding
    artwork for its media kind: waveform, photo, or filmstrip."""
    page_w, page_h, fold = round(380 * scale), round(470 * scale), round(96 * scale)
    x0, y0 = cx - page_w // 2, cy - page_h // 2
    x1, y1 = x0 + page_w, y0 + page_h
    page = [(x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)]

    # Soft drop shadow under the page, following the dog-eared outline.
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).polygon([(x, y + round(12 * scale)) for x, y in page],
                                   fill=255)
    shadow = shadow.filter(ImageFilter.GaussianBlur(16 * scale))
    layer.paste(Image.new("RGBA", (S, S), (30, 30, 40, 255)), (0, 0),
                shadow.point(lambda v: int(v * 0.30)))

    draw = ImageDraw.Draw(layer)
    draw.polygon(page, fill=(255, 255, 255, 255), outline=(140, 140, 148, 255))
    draw.line(page + [page[0]], fill=(140, 140, 148, 255),
              width=max(3, round(7 * scale)), joint="curve")

    # Dog-ear fold.
    draw.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)],
                 fill=(216, 216, 222, 255), outline=(140, 140, 148, 255))
    draw.line([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)],
              fill=(140, 140, 148, 255), width=max(3, round(6 * scale)),
              joint="curve")

    # Artwork area.
    px0, py0 = x0 + round(42 * scale), y0 + round(130 * scale)
    px1, py1 = x1 - round(42 * scale), y1 - round(48 * scale)
    if kind == "audio":
        draw_audio_art(layer, px0, py0, px1, py1)
    elif kind == "video":
        draw_video_art(layer, px0, py0, px1, py1, scale)
    else:
        draw_image_art(layer, px0, py0, px1, py1, scale, photo)


def draw_image_art(layer, px0, py0, px1, py1, scale, photo=None):
    """The original artwork: bordered photo of sky, sun, and hills — or
    `photo` center-cropped into the frame."""
    if photo is not None:
        frame_w, frame_h = px1 - px0, py1 - py0
        zoom = max(frame_w / photo.width, frame_h / photo.height)
        resized = photo.convert("RGB").resize(
            (round(photo.width * zoom), round(photo.height * zoom)),
            Image.LANCZOS)
        cx = (resized.width - frame_w) // 2
        cy = (resized.height - frame_h) // 2
        layer.paste(resized.crop((cx, cy, cx + frame_w, cy + frame_h)),
                    (px0, py0))
        ImageDraw.Draw(layer).rectangle((px0, py0, px1, py1),
                                        outline=(150, 150, 158, 255),
                                        width=max(2, round(5 * scale)))
        return

    # Sky gradient.
    sky = Image.new("RGBA", (px1 - px0, py1 - py0))
    sdraw = ImageDraw.Draw(sky)
    for y in range(sky.height):
        t = y / max(1, sky.height - 1)
        sdraw.line([(0, y), (sky.width, y)],
                   fill=(int(108 + t * 96), int(176 + t * 56),
                         int(236 + t * 14), 255))
    layer.paste(sky, (px0, py0))

    pdraw = ImageDraw.Draw(layer)
    # Sun.
    sun_r = round(46 * scale)
    sun_c = (px1 - round(78 * scale), py0 + round(84 * scale))
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
    layer.paste(overlay, (0, 0), ImageChops.multiply(overlay.split()[3], photo_mask))
    # Photo border.
    pdraw.rectangle((px0, py0, px1, py1), outline=(150, 150, 158, 255),
                    width=max(2, round(5 * scale)))


def draw_audio_art(layer, px0, py0, px1, py1):
    """Waveform bars across the middle of the page."""
    draw = ImageDraw.Draw(layer)
    w, h = px1 - px0, py1 - py0
    mid = py0 + h // 2
    heights = [0.30, 0.55, 0.80, 0.46, 1.0, 0.64, 0.88, 0.42, 0.68, 0.32]
    step = w / len(heights)
    bar_w = max(2, round(step * 0.56))
    for i, t in enumerate(heights):
        bx = px0 + round(step * i + (step - bar_w) / 2)
        bh = max(bar_w, round(h * 0.92 * t))
        draw.rounded_rectangle((bx, mid - bh // 2, bx + bar_w, mid + bh // 2),
                               radius=bar_w // 2, fill=(235, 122, 52, 255))


def draw_video_art(layer, px0, py0, px1, py1, scale):
    """Dark filmstrip frame with sprocket holes and a play triangle."""
    draw = ImageDraw.Draw(layer)
    w, h = px1 - px0, py1 - py0
    draw.rounded_rectangle((px0, py0, px1, py1), radius=round(14 * scale),
                           fill=(52, 58, 72, 255),
                           outline=(150, 150, 158, 255),
                           width=max(2, round(5 * scale)))
    # Sprocket holes along the top and bottom edges.
    hole_w, hole_h = max(2, round(w * 0.085)), max(2, round(h * 0.085))
    for row_y in (py0 + round(hole_h * 0.8), py1 - round(hole_h * 1.8)):
        for i in range(4):
            hx = px0 + w * (i + 0.5) / 4 - hole_w / 2
            draw.rounded_rectangle((hx, row_y, hx + hole_w, row_y + hole_h),
                                   radius=max(1, hole_w // 3),
                                   fill=(228, 231, 237, 255))
    # Play triangle.
    cx, cy = (px0 + px1) / 2, (py0 + py1) / 2
    tr = h * 0.26
    draw.polygon([(cx - tr * 0.68, cy - tr), (cx - tr * 0.68, cy + tr),
                  (cx + tr * 1.0, cy)], fill=(245, 247, 250, 255))


def render_icon(px, photo=None):
    """Render a master tuned for `px` and downscale it to `px`."""
    p = params_for(px)
    master = draw_docs(make_well(p), p, photo=photo)
    return master if px == S else master.resize((px, px), Image.LANCZOS)


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

    written = set()
    for filename, px, _, _ in SIZES:
        if filename in written:
            continue
        written.add(filename)
        render_icon(px).save(os.path.join(OUT_DIR, filename))

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
    Generated only if lena_std.tif is present in the repo root. Uses the full
    composition since the Dock icon is always shown large."""
    lena_path = os.path.join(os.path.dirname(__file__), "..", "lena_std.tif")
    if not os.path.exists(lena_path):
        print("lena_std.tif not found; skipping easter-egg icon")
        return
    out_dir = os.path.join(os.path.dirname(OUT_DIR), "LenaIcon.imageset")
    os.makedirs(out_dir, exist_ok=True)
    icon = render_icon(S, photo=Image.open(lena_path))
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
