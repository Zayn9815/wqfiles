#!/usr/bin/env python3
"""Generate the iPhone Duo app icon set (Pillow).

Two-tone split squircle: Natural Titanium (left) and Anodized Space Black
(right) with a central hinge hairline, a frosted optical-glass "WQ" monogram
and a fine Sapphire (#0A84FF) edge highlight.

(Script keeps its historical file name; build.sh references it.)
Usage: python3 scripts/generate_scifi_icon.py [output_dir]
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 2048
SAPPHIRE = (10, 132, 255)
ICE = (90, 200, 250)

SIZES = {
    "AppIcon1024.png": 1024,
    "AppIcon40x40@2x.png": 80,
    "AppIcon40x40@3x.png": 120,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x~ipad.png": 152,
    "AppIcon83.5x83.5@2x~ipad.png": 167,
}


def gradient(w, h, top, bottom, diagonal=False):
    img = Image.new("RGB", (w, h))
    px = ImageDraw.Draw(img)
    n = h
    for y in range(n):
        t = y / (n - 1)
        px.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def font(size):
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


def build():
    c = S // 2
    # Left: Natural Titanium. Right: Anodized Space Black.
    img = Image.new("RGB", (S, S))
    img.paste(gradient(c, S, (196, 190, 178), (128, 123, 114)), (0, 0))
    img.paste(gradient(c, S, (26, 29, 36), (9, 10, 13)), (c, 0))
    img = img.convert("RGBA")

    # Brushed texture on the titanium half
    brush = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(brush)
    for y in range(0, S, 4):
        a = 10 if (y // 4) % 3 == 0 else 0
        if a:
            bd.line([(0, y), (c, y)], fill=(255, 255, 255, a), width=2)
    img = Image.alpha_composite(img, brush)

    # Central hinge hairline: dark core with light edge.
    hinge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hinge)
    hd.rectangle([c - 5, 0, c + 4, S], fill=(0, 0, 0, 150))
    hd.rectangle([c - 7, 0, c - 6, S], fill=(255, 255, 255, 90))
    hd.rectangle([c + 5, 0, c + 6, S], fill=(255, 255, 255, 40))
    img = Image.alpha_composite(img, hinge)

    # Sapphire squircle edge highlight (fine, inset), with soft glow.
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle([46, 46, S - 47, S - 47], radius=470, outline=SAPPHIRE + (255,), width=10)
    glow = edge.filter(ImageFilter.GaussianBlur(26))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, edge)

    # Frosted optical-glass "WQ" monogram
    f = font(520)
    txt = Image.new("L", (S, S), 0)
    td = ImageDraw.Draw(txt)
    box = td.textbbox((0, 0), "WQ", font=f)
    tx = c - (box[2] - box[0]) / 2 - box[0]
    ty = c - (box[3] - box[1]) / 2 - box[1]
    td.text((tx, ty), "WQ", font=f, fill=255)

    # soft drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(txt.filter(ImageFilter.GaussianBlur(28)).point(lambda v: int(v * 0.55)))
    shadow = ImageChops.offset(shadow, 0, 22)
    img = Image.alpha_composite(img, shadow)

    # glass body: translucent white with vertical sheen
    glass = gradient(S, S, (255, 255, 255), (205, 225, 245)).convert("RGBA")
    glass.putalpha(txt.point(lambda v: int(v * 0.62)))
    img = Image.alpha_composite(img, glass)

    # crisp specular rim: letters minus slightly-eroded letters
    eroded = txt.filter(ImageFilter.MinFilter(9))
    rim = ImageChops.subtract(txt, eroded)
    rimlayer = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    rimlayer.putalpha(rim.point(lambda v: int(v * 0.85)))
    img = Image.alpha_composite(img, rimlayer)

    # sapphire inner glow tint on the right half of the letters
    tint = Image.new("RGBA", (S, S), ICE + (0,))
    half = Image.new("L", (S, S), 0)
    ImageDraw.Draw(half).rectangle([c, 0, S, S], fill=70)
    tint.putalpha(ImageChops.multiply(txt, half).filter(ImageFilter.GaussianBlur(3)))
    img = Image.alpha_composite(img, tint)

    # top specular sweep
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse([-S * 0.25, -S * 0.8, S * 1.25, S * 0.30], fill=(255, 255, 255, 20))
    img = Image.alpha_composite(img, hl)
    return img.convert("RGB")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "icons"
    os.makedirs(out, exist_ok=True)
    master = build()
    for name, px in SIZES.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out, name), "PNG")
        print("wrote", os.path.join(out, name), px)


if __name__ == "__main__":
    main()
