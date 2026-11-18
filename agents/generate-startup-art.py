#!/usr/bin/env python3
"""Generate startup-art.ansi from frame zero. Requires Pillow only at generation."""
import sys
from collections import deque
from pathlib import Path

from PIL import Image

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Downloads/1869684987069317481.gif"
image = Image.open(source)
image.seek(0)
image = image.convert("RGBA")
width, height = image.size
queue = deque([(x, y) for x in range(width) for y in (0, height - 1)]
              + [(x, y) for y in range(height) for x in (0, width - 1)])
seen = set()
while queue:
    x, y = queue.popleft()
    if (x, y) in seen:
        continue
    seen.add((x, y))
    r, g, b, _ = image.getpixel((x, y))
    # The neutral belly touches the neutral backdrop. Protect its interior,
    # using coordinates normalized to this source's 308 x 200 frame.
    sx, sy = x * 308 / width, y * 200 / height
    belly = sy > 135 and ((sx - 175) / 91) ** 2 + ((sy - 149) / 42) ** 2 < 1
    if max(r, g, b) - min(r, g, b) > 45 or belly:
        continue
    image.putpixel((x, y), (0, 0, 0, 0))
    queue.extend((nx, ny) for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1))
                 if 0 <= nx < width and 0 <= ny < height)

image = image.resize((32, 22), Image.Resampling.LANCZOS)
foreground = [image.getpixel((x, y))[:3] for y in range(22) for x in range(32)
              if image.getpixel((x, y))[3] >= 128]
samples = Image.new("RGB", (len(foreground), 1))
samples.putdata(foreground)
colors = samples.quantize(colors=11, method=Image.Quantize.MAXCOVERAGE)
quantized = image.convert("RGB").quantize(palette=colors, dither=Image.Dither.NONE)
rgb = quantized.convert("RGB")
rows = []
for y in range(0, 22, 2):
    row = []
    for x in range(32):
        upper = rgb.getpixel((x, y)) if image.getpixel((x, y))[3] >= 128 else None
        lower = rgb.getpixel((x, y + 1)) if image.getpixel((x, y + 1))[3] >= 128 else None
        codes = ["0"]
        if upper is not None:
            codes.append("38;2;%d;%d;%d" % upper)
            if lower is not None:
                codes.append("48;2;%d;%d;%d" % lower)
            glyph = "▀"
        elif lower is not None:
            codes.append("38;2;%d;%d;%d" % lower)
            glyph = "▄"
        else:
            glyph = " "
        row.append("\x1b[" + ";".join(codes) + "m" + glyph)
    rows.append("".join(row) + "\x1b[0m")
Path(__file__).with_name("startup-art.ansi").write_text("\n".join(rows) + "\n", encoding="utf-8")
