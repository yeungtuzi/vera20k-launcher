#!/usr/bin/env python3
"""Compose the launcher icon: the project's RA star plus a large play mark.

The mark has to survive Dock (48 px) and Cmd-Tab (32 px) sizes, so it is a
disc that fills most of the canvas with a triangle that spans roughly half of
that disc's width.
"""

import sys

from PIL import Image, ImageDraw, ImageFilter


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make_icon.py <source.png> <out.png>", file=sys.stderr)
        return 2
    source, out = sys.argv[1], sys.argv[2]

    base = Image.open(source).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    # Darken the artwork a little: the play mark is the thing that must read.
    base = Image.alpha_composite(base, Image.new("RGBA", base.size, (0, 0, 0, 95)))

    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy, radius = 512, 512, 330
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(8, 12, 8, 230),
        outline=(96, 232, 118, 255),
        width=30,
    )
    half_h = int(radius * 0.62)
    back_x = cx - int(radius * 0.32)
    tip_x = cx + int(radius * 0.50)
    draw.polygon(
        [(back_x, cy - half_h), (back_x, cy + half_h), (tip_x, cy)],
        fill=(246, 255, 246, 255),
    )

    glow = layer.filter(ImageFilter.GaussianBlur(20))
    composed = Image.alpha_composite(Image.alpha_composite(base, glow), layer)
    composed.convert("RGB").save(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
