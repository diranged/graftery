#!/usr/bin/env python3

# Copyright 2026 Matt Wise
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Generates the DMG installer background image for Graftery.

Color palette is drawn from docs/icon.svg:
  - Dark teal background: #0a1a20
  - Teal strand:          #0e6878
  - Darker teal strand:   #094858
  - Light teal accent:    #1a8090
  - Coral accent:         #c94a30 / #e86040 / #f07050

DMG window is 600x400.  Icon centres:
  - Graftery.app  at (175, 190)
  - Applications  at (425, 190)
The arrow sits in the gap between them.
"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, os

WIDTH, HEIGHT = 600, 400

# --- palette (from icon.svg) ---
BG_DARK   = (10, 26, 32)       # #0a1a20
BG_MID    = (14, 50, 62)       # #0e323e  (interpolated)
TEAL      = (14, 104, 120)     # #0e6878
TEAL_DK   = (9, 72, 88)       # #094858
TEAL_LT   = (26, 128, 144)    # #1a8090
CORAL     = (201, 74, 48)      # #c94a30
CORAL_LT  = (240, 112, 80)    # #f07050
CORAL_BRT = (232, 96, 64)      # #e86040


def lerp_color(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def draw_gradient_bg(img):
    """Radial gradient: slightly lighter in centre, dark at edges."""
    draw = ImageDraw.Draw(img)
    cx, cy = WIDTH // 2, HEIGHT // 2
    max_dist = math.hypot(cx, cy)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            d = math.hypot(x - cx, y - cy) / max_dist
            t = d * d  # ease-out for subtlety
            color = lerp_color(BG_MID, BG_DARK, t)
            draw.point((x, y), fill=(*color, 255))


def draw_subtle_helix(img):
    """Draw faint helix curves echoing the icon DNA motif."""
    for strand_offset, color, alpha in [(0, TEAL, 30), (math.pi, TEAL_DK, 24)]:
        overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
        od = ImageDraw.Draw(overlay)
        amplitude = 70
        freq = 2.5 * math.pi / WIDTH
        cy = HEIGHT // 2
        prev = None
        for x in range(WIDTH):
            y = int(cy + amplitude * math.sin(freq * x + strand_offset))
            if prev is not None:
                od.line([prev, (x, y)], fill=(*color, alpha), width=4)
            prev = (x, y)
        img.paste(Image.alpha_composite(
            Image.new("RGBA", img.size, (0, 0, 0, 0)), overlay), mask=overlay)

    # Faint crossbars at helix crossing points
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    freq = 2.5 * math.pi / WIDTH
    cy = HEIGHT // 2
    for x in range(0, WIDTH, 8):
        y1 = int(cy + 70 * math.sin(freq * x))
        y2 = int(cy + 70 * math.sin(freq * x + math.pi))
        # Only draw crossbars near where strands are close
        if abs(y1 - y2) < 50:
            od.line([(x, y1), (x, y2)], fill=(*TEAL_LT, 12), width=1)
    img.paste(Image.alpha_composite(
        Image.new("RGBA", img.size, (0, 0, 0, 0)), overlay), mask=overlay)


def draw_arrow(img):
    """Draw a coral arrow with glow from app icon area to Applications area."""
    y = 190
    x_start = 238
    x_end = 362
    head_size = 20

    # --- Glow layer (blurred coral on transparent) ---
    glow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    # Thick soft shaft
    gd.line([(x_start - 4, y), (x_end - head_size + 4, y)],
            fill=(*CORAL, 80), width=14)
    # Soft arrowhead
    head_pts = [
        (x_end + 4, y),
        (x_end - head_size - 4, y - head_size // 2 - 6),
        (x_end - head_size - 4, y + head_size // 2 + 6),
    ]
    gd.polygon(head_pts, fill=(*CORAL, 80))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=10))
    img.paste(Image.alpha_composite(
        Image.new("RGBA", img.size, (0, 0, 0, 0)), glow), mask=glow)

    # --- Crisp arrow on top ---
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    # Shaft with rounded ends
    od.line([(x_start, y), (x_end - head_size, y)],
            fill=(*CORAL_BRT, 230), width=4)
    # Round caps
    od.ellipse([(x_start - 2, y - 2), (x_start + 2, y + 2)],
               fill=(*CORAL_BRT, 230))

    # Arrowhead
    head_pts = [
        (x_end, y),
        (x_end - head_size, y - head_size // 2 - 2),
        (x_end - head_size, y + head_size // 2 + 2),
    ]
    od.polygon(head_pts, fill=(*CORAL_LT, 240))
    od.polygon(head_pts, outline=(*CORAL, 200))

    img.paste(Image.alpha_composite(
        Image.new("RGBA", img.size, (0, 0, 0, 0)), overlay), mask=overlay)


def draw_labels(img):
    """Draw centred labels below icon positions."""
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFNSText.ttf", 13)
        except (OSError, IOError):
            font = ImageFont.load_default()

    for text, cx in [("Graftery", 175), ("Applications", 425)]:
        bbox = od.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        od.text((cx - tw // 2, 258), text, fill=(*TEAL_LT, 200), font=font)

    img.paste(Image.alpha_composite(
        Image.new("RGBA", img.size, (0, 0, 0, 0)), overlay), mask=overlay)


def draw_top_accent(img):
    """Thin teal accent line at the very top."""
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for y in range(3):
        alpha = int(40 * (1.0 - y / 3.0))
        od.line([(0, y), (WIDTH, y)], fill=(*TEAL_DK, alpha))
    img.paste(Image.alpha_composite(
        Image.new("RGBA", img.size, (0, 0, 0, 0)), overlay), mask=overlay)


def main():
    img = Image.new("RGBA", (WIDTH, HEIGHT), (*BG_DARK, 255))

    draw_gradient_bg(img)
    draw_subtle_helix(img)
    draw_top_accent(img)
    draw_arrow(img)
    draw_labels(img)

    # Final output as RGB PNG (DMG backgrounds don't need alpha)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "dmg-background.png")
    img.convert("RGB").save(out, "PNG")
    print(f"Created {out}  ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
