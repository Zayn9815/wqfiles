#!/usr/bin/env python3
"""Render WQ Glass bespoke Crimson Liquid Glass 'Z' app icon into icons/."""
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "icons"
SIZE = 2048  # 2x supersampling for crisp edges -> 1024x1024


def lerp_color(c1, c2, t):
    return tuple(int(round(c1[i] + (c2[i] - c1[i]) * t)) for i in range(len(c1)))


def draw_gradient_bg(size: int) -> Image.Image:
    # Vertical + subtle diagonal crimson/burgundy gradient (#5C1D1B -> #782623 -> #4A1412)
    top = (0x5C, 0x1D, 0x1B)
    mid = (0x78, 0x26, 0x23)
    edge = (0x4A, 0x14, 0x12)
    strip = Image.new("RGBA", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / (size - 1)
        if t < 0.48:
            c = lerp_color(top, mid, t / 0.48)
        else:
            c = lerp_color(mid, edge, (t - 0.48) / 0.52)
        px[0, y] = (*c, 255)
    bg = strip.resize((size, size), Image.Resampling.BILINEAR)

    # Warm coral/terracotta ambient radial glow pools
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [int(size * 0.08), int(size * 0.04), int(size * 0.92), int(size * 0.88)],
        fill=(210, 74, 66, 95),
    )
    gd.ellipse(
        [int(size * -0.15), int(size * -0.15), int(size * 0.65), int(size * 0.65)],
        fill=(242, 128, 118, 65),
    )
    gd.ellipse(
        [int(size * 0.35), int(size * 0.45), int(size * 1.15), int(size * 1.15)],
        fill=(55, 12, 12, 110),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=int(size * 0.16)))
    return Image.alpha_composite(bg, glow)


def squircle_mask(size: int, box, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle(box, radius=radius, fill=255)
    return mask


def render_master() -> Image.Image:
    s = SIZE
    canvas = draw_gradient_bg(s)

    # Outer frosted crimson-rose glass squircle prism plate
    pad = int(s * 0.125)
    plate_box = [pad, pad, s - pad, s - pad]
    plate_radius = int(s * 0.21)

    # Drop shadow under the glass prism plate
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    s_off = int(s * 0.025)
    sd.rounded_rectangle(
        [pad, pad + s_off, s - pad, s - pad + s_off],
        radius=plate_radius,
        fill=(32, 6, 6, 155),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=int(s * 0.045)))
    canvas = Image.alpha_composite(canvas, shadow)

    # Frosted crimson-rose glass plate body
    plate_mask = squircle_mask(s, plate_box, plate_radius)
    plate_grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    pgd = ImageDraw.Draw(plate_grad)
    # Translucent rose-crimson tint
    pgd.rounded_rectangle(plate_box, radius=plate_radius, fill=(168, 64, 58, 122))
    # Bright blush refraction glow in top-left interior
    inner_glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    igd = ImageDraw.Draw(inner_glow)
    igd.ellipse(
        [int(s * 0.05), int(s * 0.02), int(s * 0.78), int(s * 0.65)],
        fill=(255, 206, 202, 72),
    )
    inner_glow = inner_glow.filter(ImageFilter.GaussianBlur(radius=int(s * 0.10)))
    inner_glow = ImageChops.composite(inner_glow, Image.new("RGBA", (s, s), (0, 0, 0, 0)), plate_mask)
    canvas = Image.alpha_composite(canvas, plate_grad)
    canvas = Image.alpha_composite(canvas, inner_glow)

    # Diagonal glass refraction sheen band across top half
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shd = ImageDraw.Draw(sheen)
    shd.polygon(
        [
            (int(s * 0.05), int(s * 0.36)),
            (int(s * 0.62), int(s * 0.05)),
            (int(s * 0.95), int(s * 0.05)),
            (int(s * 0.12), int(s * 0.62)),
        ],
        fill=(255, 234, 232, 40),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=int(s * 0.03)))
    sheen = ImageChops.composite(sheen, Image.new("RGBA", (s, s), (0, 0, 0, 0)), plate_mask)
    canvas = Image.alpha_composite(canvas, sheen)

    # Coral-white specular rim on the glass plate (brighter top-left edge)
    rim = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle(
        plate_box,
        radius=plate_radius,
        outline=(255, 224, 222, 165),
        width=max(4, int(s * 0.0065)),
    )
    # Soft top highlight arc
    rd.rounded_rectangle(
        [pad + 4, pad + 4, s - pad - 4, s - pad - 4],
        radius=plate_radius - 4,
        outline=(255, 245, 244, 65),
        width=max(2, int(s * 0.003)),
    )
    canvas = Image.alpha_composite(canvas, rim)

    # Single continuous geometric Z polygon (no internal seam lines)
    z_left = s * 0.295
    z_right = s * 0.705
    z_top = s * 0.285
    z_bottom = s * 0.715
    bar = s * 0.094
    diag_w = bar * 1.18
    slope = (z_bottom - z_top - 2 * bar) / ((z_right - diag_w) - (z_left + diag_w))
    # Outer clockwise contour of a clean modern geometric Z
    z_poly = [
        (z_left, z_top),
        (z_right, z_top),
        (z_right, z_top + bar),
        (z_left + diag_w, z_bottom - bar),
        (z_right, z_bottom - bar),
        (z_right, z_bottom),
        (z_left, z_bottom),
        (z_left, z_bottom - bar),
        (z_right - diag_w, z_top + bar),
        (z_left, z_top + bar),
    ]
    _ = slope  # keeps geometry reference clear

    z_shape = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    zd = ImageDraw.Draw(z_shape)
    zd.polygon(z_poly, fill=(255, 255, 255, 255))

    # Depth shadow beneath the Z emblem
    z_alpha = z_shape.split()[3]
    z_shadow = Image.new("RGBA", (s, s), (38, 6, 6, 185))
    z_shadow.putalpha(z_alpha)
    z_shadow_shifted = ImageChops.offset(z_shadow, 0, int(s * 0.018))
    z_shadow_shifted = z_shadow_shifted.filter(ImageFilter.GaussianBlur(radius=int(s * 0.024)))
    canvas = Image.alpha_composite(canvas, z_shadow_shifted)

    # Frosted-white Z body with subtle crimson-blush bottom tint
    z_grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    zgd = ImageDraw.Draw(z_grad)
    for y in range(int(z_top), int(z_bottom) + 1):
        t = (y - z_top) / max(1.0, (z_bottom - z_top))
        c = lerp_color((255, 255, 255), (255, 226, 224), t)
        zgd.line([(int(z_left), y), (int(z_right), y)], fill=(*c, 250))
    z_layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    z_layer = ImageChops.composite(z_grad, z_layer, z_alpha)
    canvas = Image.alpha_composite(canvas, z_layer)

    # Specular outer rim around the seamless Z contour
    z_bevel = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    zbd = ImageDraw.Draw(z_bevel)
    zbd.line(z_poly + [z_poly[0]], fill=(255, 255, 255, 255), width=max(2, int(s * 0.004)), joint="curve")
    canvas = Image.alpha_composite(canvas, z_bevel)

    # Downsample to 1024x1024 RGB (App Store / iOS icons must be opaque RGB PNGs)
    master_rgba = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
    master = master_rgba.convert("RGB")
    return master


def main() -> None:
    ICONS.mkdir(parents=True, exist_ok=True)
    master = render_master()
    master.save(ICONS / "AppIcon1024.png", format="PNG", optimize=True)
    targets = {
        "AppIcon40x40@2x.png": 80,
        "AppIcon40x40@3x.png": 120,
        "AppIcon60x60@2x.png": 120,
        "AppIcon60x60@3x.png": 180,
        "AppIcon76x76@2x~ipad.png": 152,
        "AppIcon83.5x83.5@2x~ipad.png": 167,
    }
    for filename, px in targets.items():
        resized = master.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(ICONS / filename, format="PNG", optimize=True)
    print(f"Generated {len(targets) + 1} WQ Glass icons in {ICONS}")


if __name__ == "__main__":
    main()
