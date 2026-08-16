#!/usr/bin/env python3
"""Generate Andy题词 AppIcon (黑金 #FFD700 on #0A0A0A) at all required macOS sizes.

Outputs PNG files into Textream/Textream/Assets.xcassets/AppIcon.appiconset/,
overwriting the placeholder icons.
"""
from PIL import Image, ImageDraw, ImageFont
import os
import sys

BG = (10, 10, 10, 255)          # #0A0A0A
GOLD = (255, 215, 0, 255)       # #FFD700
ICON_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Textream", "Textream", "Assets.xcassets", "AppIcon.appiconset",
)

SIZES = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),       # 16pt @2x
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),       # 32pt @2x
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),    # 128pt @2x
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),    # 256pt @2x
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),   # 512pt @2x
]


def find_font(size: int) -> ImageFont.FreeTypeFont:
    """Best-effort Chinese-capable bold font, falling back to default."""
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size=size)
            except Exception:
                continue
    return ImageFont.load_default()


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), BG)
    draw = ImageDraw.Draw(img)
    # Outer gold ring (subtle, for premium feel)
    ring_pad = max(2, size // 16)
    ring_w = max(1, size // 64)
    draw.ellipse(
        (ring_pad, ring_pad, size - ring_pad - 1, size - ring_pad - 1),
        outline=GOLD,
        width=ring_w,
    )
    # Central "题" character in gold, fills most of the canvas
    glyph = "题"
    font_size = int(size * 0.62)
    font = find_font(font_size)
    bbox = draw.textbbox((0, 0), glyph, font=font)
    gw = bbox[2] - bbox[0]
    gh = bbox[3] - bbox[1]
    # Center using actual ink metrics (account for descender)
    x = (size - gw) / 2 - bbox[0]
    y = (size - gh) / 2 - bbox[1] - max(0, bbox[3]) * 0.05
    draw.text((x, y), glyph, fill=GOLD, font=font)
    return img


def main() -> int:
    os.makedirs(ICON_DIR, exist_ok=True)
    for size, name in SIZES:
        out = os.path.join(ICON_DIR, name)
        icon = draw_icon(size)
        icon.save(out, "PNG")
        print(f"  {name} ({size}x{size})")
    print(f"Wrote {len(SIZES)} icons to {ICON_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
