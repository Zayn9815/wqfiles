#!/usr/bin/env python3
"""Generate the Sci-Fi Glacier Cyber-Shield "WQ" app icon set (Pillow).

Usage: python3 scripts/generate_scifi_icon.py [output_dir]
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 2048  # supersampled canvas
CYAN = (0, 245, 255)
AURORA = (79, 255, 176)

SIZES = {
    "AppIcon1024.png": 1024,
    "AppIcon40x40@2x.png": 80,
    "AppIcon40x40@3x.png": 120,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x~ipad.png": 152,
    "AppIcon83.5x83.5@2x~ipad.png": 167,
}


def vgradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        px.line([(0, y), (size, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def glow(layer, radius, strength=1.0):
    blur = layer.filter(ImageFilter.GaussianBlur(radius))
    if strength != 1.0:
        blur = blur.point(lambda v: min(255, int(v * strength)))
    return blur


def find_font(size):
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
              "/System/Library/Fonts/Helvetica.ttc"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def shield_points(cx, cy, w, h):
    return [(cx, cy - h / 2), (cx + w / 2, cy - h * 0.34), (cx + w * 0.46, cy + h * 0.14),
            (cx, cy + h / 2), (cx - w * 0.46, cy + h * 0.14), (cx - w / 2, cy - h * 0.34)]


def build():
    c = S // 2
    # Deep sub-zero background #050E1A -> #0D253A
    img = vgradient(S, (5, 14, 26), (13, 37, 58)).convert("RGBA")

    # Brushed metallic ice-silver beveled outer frame
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    for i in range(0, 56):
        t = i / 55
        v = int(228 - 120 * t)
        fd.rounded_rectangle([i, i, S - 1 - i, S - 1 - i], radius=int(S * 0.22) - i,
                             outline=(v - 12, v, min(255, v + 18), 255), width=1)
    img = Image.alpha_composite(img, frame)

    # Concentric HUD targeting rings
    rings = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rings)
    for r, col, wd, a in [(860, CYAN, 6, 150), (760, AURORA, 10, 190), (660, CYAN, 4, 120), (560, CYAN, 8, 170)]:
        rd.ellipse([c - r, c - r, c + r, c + r], outline=col + (a,), width=wd)
    for k in range(48):  # tick marks
        ang = math.radians(k * 7.5)
        r0, r1 = (820, 880) if k % 4 == 0 else (845, 880)
        rd.line([(c + r0 * math.cos(ang), c + r0 * math.sin(ang)),
                 (c + r1 * math.cos(ang), c + r1 * math.sin(ang))], fill=CYAN + (200,), width=7)
    for a0, a1 in [(200, 250), (20, 70)]:  # bright arc segments
        rd.arc([c - 760, c - 760, c + 760, c + 760], a0, a1, fill=AURORA + (255,), width=18)
    img = Image.alpha_composite(img, glow(rings, 22, 1.4))
    img = Image.alpha_composite(img, rings)

    # Holographic cyber shield
    sh = shield_points(c, c + 10, 760, 880)
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(body).polygon(sh, fill=(10, 40, 66, 235))
    img = Image.alpha_composite(img, body)
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.line(sh + [sh[0]], fill=CYAN + (255,), width=16, joint="curve")
    inner = shield_points(c, c + 10, 690, 800)
    ed.line(inner + [inner[0]], fill=(200, 250, 255, 150), width=5, joint="curve")
    img = Image.alpha_composite(img, glow(edge, 18, 1.6))
    img = Image.alpha_composite(img, edge)

    # Crystalline glowing "WQ"
    font = find_font(430)
    txt = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(txt)
    box = td.textbbox((0, 0), "WQ", font=font)
    tx = c - (box[2] - box[0]) / 2 - box[0]
    ty = c + 10 - (box[3] - box[1]) / 2 - box[1]
    td.text((tx, ty), "WQ", font=font, fill=(235, 255, 255, 255))
    mask = txt.split()[3]
    tint = Image.new("RGBA", (S, S), CYAN + (0,))
    tint.putalpha(mask)
    img = Image.alpha_composite(img, glow(tint, 30, 2.0))
    # vertical ice gradient inside letters
    grad = vgradient(S, (255, 255, 255), (128, 240, 255)).convert("RGBA")
    grad.putalpha(mask)
    img = Image.alpha_composite(img, grad)

    # Specular top highlight
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse([-S * 0.2, -S * 0.75, S * 1.2, S * 0.28], fill=(220, 250, 255, 26))
    img = Image.alpha_composite(img, hl)
    return img.convert("RGB")  # iOS icons must be opaque, system applies the mask


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "icons"
    os.makedirs(out, exist_ok=True)
    master = build()
    for name, px in SIZES.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out, name), "PNG")
        print("wrote", os.path.join(out, name), px)


if __name__ == "__main__":
    main()
