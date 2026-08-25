#!/usr/bin/env python3
"""Factory Commons board art.

Two jobs in one committed, deterministic script:

1. **Split the nano-banana sheets.** The three cog bodies, the three locker-room
   portraits and the locker-room background are `gemini-2.5-flash-image`
   ("nano-banana") renders of the Softmax cog, kept under
   `scripts/art/source/`. This script chroma-keys them off their flat green
   backdrop, splits the rows, trims, pads and resizes them into the sprites the
   engine loads. Regenerating the sprites needs no API call — the sheets are
   committed, so the assets are reproducible rather than mysterious.

2. **Draw the plant procedurally** (Pillow): the steel floor, the wall panels,
   the four machine states, the console and its two levers, the maintenance
   bay, the two dispenser mouths, the two hopper intakes, the belt segment and
   its chevron, the chute, the two cube colours, the banana, and the press /
   override effect plates. These are machinery, not characters — a procedural
   draw is the right tool and keeps the palette exactly in step with the
   viewer chrome.

Files this script OWNS (nothing else writes them):

    data/floor_steel.png            data/wall_panel_h.png
    data/wall_panel_v.png           data/machine_prime.png
    data/machine_worn.png           data/machine_failing.png
    data/machine_scrap.png          data/console.png
    data/lever_cycle.png            data/lever_override.png
    data/bay.png                    data/dispenser_pink.png
    data/dispenser_blue.png         data/hopper_pink.png
    data/hopper_blue.png            data/belt_seg.png
    data/belt_chevron.png           data/chute.png
    data/cube_pink.png              data/cube_blue.png
    data/banana.png                 data/press_flash.png
    data/strip_smoke.png            data/label_bolt.png
    data/label_cotter.png           data/label_ratchet.png
    data/cog_{red,blue,yellow}_front.png
    data/cog_{red,blue,yellow}_carry.png
    client/art/lockerroom/bg.jpg
    client/art/lockerroom/{red,blue,yellow}_1.webp

ALPHA IS BINARY in every sprite: 0 or 255, never in between. `src/factory_commons/global.nim`
reads the decoded pixels straight out of pixie's PREMULTIPLIED buffer, and
premultiplied equals straight alpha exactly when alpha is 0 or 255. A sprite
with a soft edge would ship a dark fringe.

    python3 scripts/art/gen_factory_commons_art.py
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "data")
LOCKER = os.path.join(ROOT, "client", "art", "lockerroom")
SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "source")

CELL = 48

# The palette is the viewer chrome's, so board and HUD read as one composition.
INK = (18, 13, 10, 255)
STEEL = (58, 60, 64, 255)
STEEL_DARK = (41, 43, 47, 255)
STEEL_LIGHT = (78, 81, 86, 255)
RIVET = (96, 99, 104, 255)
AMBER = (232, 163, 61, 255)
PINK = (214, 96, 148, 255)
BLUE = (63, 124, 196, 255)
RED = (224, 82, 58, 255)
PAPER = (242, 232, 216, 255)
BANANA = (221, 197, 49, 255)
SEAT_TINT = {"red": (224, 82, 58), "blue": (63, 124, 196), "yellow": (221, 197, 49)}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def binarize(image: Image.Image, threshold: int = 128) -> Image.Image:
    """Force alpha to 0 or 255. See the module docstring — this is load-bearing."""
    image = image.convert("RGBA")
    r, g, b, a = image.split()
    a = a.point(lambda v: 255 if v >= threshold else 0)
    return Image.merge("RGBA", (r, g, b, a))


def save(image: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    binarize(image).save(path, optimize=True)
    print(f"  {os.path.relpath(path, ROOT)}  {image.size[0]}x{image.size[1]}")


def rivets(draw: ImageDraw.ImageDraw, box, step: int = 12, colour=RIVET) -> None:
    x0, y0, x1, y1 = box
    for x in range(x0 + 3, x1 - 2, step):
        for y in range(y0 + 3, y1 - 2, step):
            draw.rectangle([x, y, x + 1, y + 1], fill=colour)


def hatch(draw: ImageDraw.ImageDraw, box, colour, step: int = 6) -> None:
    x0, y0, x1, y1 = box
    for offset in range(-(y1 - y0), x1 - x0, step):
        draw.line([(x0 + offset, y1), (x0 + offset + (y1 - y0), y0)], fill=colour)


# ---------------------------------------------------------------------------
# the plant
# ---------------------------------------------------------------------------
def floor_steel() -> Image.Image:
    image = Image.new("RGBA", (CELL, CELL), STEEL)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, CELL - 1, CELL - 1], outline=STEEL_DARK)
    draw.line([(0, CELL - 1), (CELL - 1, CELL - 1)], fill=(34, 36, 39, 255))
    draw.line([(0, 0), (CELL - 1, 0)], fill=STEEL_LIGHT)
    rivets(draw, (0, 0, CELL, CELL), step=20)
    # A faint diagonal tread so a 48px tile does not read as flat paint.
    for x in range(0, CELL, 8):
        draw.line([(x, CELL - 1), (x + 10, CELL - 11)], fill=(63, 65, 70, 255))
    return image


def wall_panel(vertical: bool) -> Image.Image:
    image = Image.new("RGBA", (CELL, CELL), (30, 31, 35, 255))
    draw = ImageDraw.Draw(image)
    if vertical:
        for x in range(4, CELL, 14):
            draw.rectangle([x, 2, x + 8, CELL - 3], fill=(44, 46, 50, 255))
            draw.rectangle([x, 2, x + 8, CELL - 3], outline=(22, 23, 26, 255))
    else:
        for y in range(4, CELL, 14):
            draw.rectangle([2, y, CELL - 3, y + 8], fill=(44, 46, 50, 255))
            draw.rectangle([2, y, CELL - 3, y + 8], outline=(22, 23, 26, 255))
    rivets(draw, (0, 0, CELL, CELL), step=15, colour=(70, 72, 76, 255))
    return image


def machine(state: str) -> Image.Image:
    """The 5x5 common-pool asset, 240x240, in four art states.

    The seam is the gauge made physical: bright amber at PRIME, dim at WORN,
    red at FAILING, dead at SCRAP.
    """
    size = CELL * 5
    seam = {
        "prime": AMBER,
        "worn": (172, 121, 47, 255),
        "failing": (196, 84, 48, 255),
        "scrap": (58, 42, 34, 255),
    }[state]
    body = {
        "prime": (74, 77, 82, 255),
        "worn": (66, 68, 72, 255),
        "failing": (58, 56, 56, 255),
        "scrap": (44, 41, 40, 255),
    }[state]
    image = Image.new("RGBA", (size, size), body)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, size - 1, size - 1], outline=(24, 25, 28, 255), width=3)
    draw.rectangle([10, 10, size - 11, size - 11], outline=(30, 32, 35, 255), width=2)
    # Two big riveted plates.
    for box in [(20, 20, size - 21, size // 2 - 8), (20, size // 2 + 8, size - 21, size - 21)]:
        draw.rectangle(list(box), fill=(int(body[0] * 1.08), int(body[1] * 1.08), int(body[2] * 1.08), 255))
        draw.rectangle(list(box), outline=(28, 30, 33, 255), width=2)
        rivets(draw, box, step=22)
    # The glowing seam across the middle.
    draw.rectangle([16, size // 2 - 6, size - 17, size // 2 + 6], fill=(20, 18, 17, 255))
    draw.rectangle([20, size // 2 - 3, size - 21, size // 2 + 3], fill=seam)
    # A pressure gauge dial, top-left, so the block reads as machinery.
    draw.ellipse([28, 30, 64, 66], fill=(26, 27, 30, 255), outline=seam, width=2)
    draw.line([(46, 48), (46 + 12, 48 - 8)], fill=seam, width=2)
    if state == "scrap":
        # Cracks and a dead dial: the plant is finished, forever.
        for a, b in [((30, 60), (120, 150)), ((150, 40), (200, 130)), ((70, 200), (140, 150))]:
            draw.line([a, b], fill=(24, 22, 21, 255), width=3)
        hatch(draw, (20, 20, size - 21, size - 21), (52, 40, 38, 255), step=18)
    if state == "failing":
        hatch(draw, (20, size // 2 + 8, size - 21, size - 21), (92, 52, 44, 255), step=16)
    return image


def console() -> Image.Image:
    """The three-cell console pad. The levers ride on top as their own sprites."""
    image = Image.new("RGBA", (CELL * 3, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([2, 8, CELL * 3 - 3, CELL - 3], fill=(50, 52, 56, 255))
    draw.rectangle([2, 8, CELL * 3 - 3, CELL - 3], outline=(24, 25, 28, 255), width=2)
    draw.rectangle([8, 14, CELL * 3 - 9, 26], fill=(30, 32, 35, 255))
    for x in range(14, CELL * 3 - 14, 10):
        draw.rectangle([x, 17, x + 5, 23], fill=AMBER if (x // 10) % 3 else (86, 132, 92, 255))
    rivets(draw, (2, 28, CELL * 3 - 3, CELL - 3), step=16)
    return image


def lever(kind: str) -> Image.Image:
    """A 24x48 lever. `cycle` is green and sober; `override` is red and hot."""
    image = Image.new("RGBA", (24, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    knob = (86, 168, 94, 255) if kind == "cycle" else RED
    draw.rectangle([8, 30, 15, CELL - 6], fill=(40, 42, 46, 255))
    draw.rectangle([6, 26, 17, 34], fill=(30, 32, 35, 255))
    draw.line([(11, 30), (11 if kind == "cycle" else 17, 10)], fill=(58, 60, 64, 255), width=4)
    draw.ellipse([(4 if kind == "cycle" else 10), 2, (18 if kind == "cycle" else 23), 16], fill=knob)
    draw.ellipse([(7 if kind == "cycle" else 13), 5, (13 if kind == "cycle" else 19), 11],
                 fill=(255, 255, 255, 255) if kind == "override" else (200, 236, 204, 255))
    return image


def bay() -> Image.Image:
    """The maintenance bay: one cell wide, three tall, with a tool rack."""
    image = Image.new("RGBA", (CELL, CELL * 3), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([4, 4, CELL - 5, CELL * 3 - 5], fill=(46, 48, 52, 255))
    draw.rectangle([4, 4, CELL - 5, CELL * 3 - 5], outline=AMBER, width=2)
    hatch(draw, (6, 6, CELL - 7, CELL * 3 - 7), (62, 56, 44, 255), step=10)
    # Tool rack: a spanner, a wrench and an oil can, top to bottom.
    draw.rectangle([12, 16, 36, 22], fill=(150, 154, 160, 255))
    draw.ellipse([10, 12, 22, 26], outline=(150, 154, 160, 255), width=3)
    draw.rectangle([16, 70, 32, 76], fill=(170, 174, 180, 255))
    draw.rectangle([12, 62, 22, 84], fill=(170, 174, 180, 255))
    draw.polygon([(16, 116), (34, 116), (34, 132), (16, 132)], fill=(120, 96, 64, 255))
    draw.line([(34, 120), (44, 110)], fill=(120, 96, 64, 255), width=3)
    return image


def funnel(colour, mouth: bool) -> Image.Image:
    """A dispenser mouth (emits) or a hopper intake (consumes).

    They are deliberately different SHAPES, not just different labels: the
    dispenser is a chute pointing down onto the belt, the hopper is a grated
    intake pointing up into the machine.
    """
    image = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if mouth:
        draw.polygon([(6, 4), (CELL - 7, 4), (CELL - 15, 30), (14, 30)], fill=(52, 54, 58, 255))
        draw.polygon([(6, 4), (CELL - 7, 4), (CELL - 15, 30), (14, 30)], outline=colour)
        draw.rectangle([16, 30, CELL - 17, 40], fill=colour)
        draw.rectangle([12, 40, CELL - 13, CELL - 5], fill=(38, 40, 44, 255))
    else:
        draw.polygon([(14, CELL - 5), (CELL - 15, CELL - 5), (CELL - 7, 12), (6, 12)],
                     fill=(52, 54, 58, 255))
        draw.polygon([(14, CELL - 5), (CELL - 15, CELL - 5), (CELL - 7, 12), (6, 12)],
                     outline=colour)
        for x in range(10, CELL - 9, 7):
            draw.line([(x, 12), (x, CELL - 6)], fill=colour)
        draw.rectangle([4, 6, CELL - 5, 13], fill=colour)
    return image


def belt_seg() -> Image.Image:
    image = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 8, CELL - 1, CELL - 9], fill=(34, 35, 38, 255))
    draw.rectangle([0, 8, CELL - 1, 12], fill=(60, 62, 66, 255))
    draw.rectangle([0, CELL - 13, CELL - 1, CELL - 9], fill=(60, 62, 66, 255))
    for x in range(0, CELL, 8):
        draw.line([(x, 14), (x, CELL - 14)], fill=(46, 48, 51, 255))
    return image


def belt_chevron() -> Image.Image:
    image = Image.new("RGBA", (24, 24), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.polygon([(4, 4), (16, 12), (4, 20), (9, 12)], fill=(150, 122, 66, 255))
    return image


def chute() -> Image.Image:
    """Three cells of grated ramp. Bananas land here and anybody may eat them."""
    image = Image.new("RGBA", (CELL * 3, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([2, 2, CELL * 3 - 3, CELL - 7], fill=(44, 42, 34, 255))
    draw.rectangle([2, 2, CELL * 3 - 3, CELL - 7], outline=BANANA, width=2)
    for x in range(8, CELL * 3 - 8, 9):
        draw.line([(x, 6), (x, CELL - 11)], fill=(96, 88, 44, 255), width=2)
    draw.rectangle([2, CELL - 7, CELL * 3 - 3, CELL - 3], fill=(28, 27, 22, 255))
    return image


def cube(colour, notched: bool) -> Image.Image:
    """A 22px cube, readable by SHAPE as well as colour.

    Pink carries a notched (hexagonal) top face, blue a plain bevel — so the
    two feedstocks stay distinguishable in a screenshot, a colour-blind
    viewer's browser, and a 360px featured-match iframe.
    """
    image = Image.new("RGBA", (22, 22), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    light = tuple(min(255, int(c * 1.35)) for c in colour[:3]) + (255,)
    dark = tuple(int(c * 0.6) for c in colour[:3]) + (255,)
    draw.rectangle([2, 6, 19, 19], fill=colour, outline=INK)
    if notched:
        draw.polygon([(2, 6), (7, 1), (14, 1), (19, 6), (14, 10), (7, 10)], fill=light, outline=INK)
    else:
        draw.polygon([(2, 6), (6, 2), (19, 2), (19, 6)], fill=light, outline=INK)
    draw.line([(3, 18), (18, 18)], fill=dark)
    return image


def banana() -> Image.Image:
    image = Image.new("RGBA", (20, 20), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.polygon([(3, 14), (6, 5), (12, 3), (17, 7), (16, 12), (10, 17)], fill=BANANA, outline=INK)
    draw.polygon([(6, 12), (8, 7), (12, 6), (14, 9)], fill=(240, 224, 96, 255))
    draw.rectangle([2, 13, 5, 16], fill=(96, 76, 30, 255))
    return image


def effect(kind: str) -> Image.Image:
    """A 240x240 plate drawn over the machine for a handful of ticks."""
    size = CELL * 5
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if kind == "press":
        for i, radius in enumerate(range(size // 2, 20, -18)):
            shade = (255, 214 - i * 12, 120 - i * 10, 255)
            draw.ellipse([size // 2 - radius, size // 2 - radius,
                          size // 2 + radius, size // 2 + radius], outline=shade, width=5)
    else:
        for i, (cx, cy, r) in enumerate([(120, 70, 46), (86, 40, 32), (154, 36, 28),
                                         (112, 20, 22), (150, 92, 24)]):
            grey = 150 - i * 14
            draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(grey, grey - 6, grey - 12, 255))
        draw.rectangle([16, size // 2 - 8, size - 17, size // 2 + 8], fill=(206, 76, 52, 255))
    return image.filter(ImageFilter.GaussianBlur(1))


def label(text: str) -> Image.Image:
    """The alias plate drawn under a cog's feet."""
    font = ImageFont.load_default()
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    box = probe.textbbox((0, 0), text, font=font)
    width = max(28, box[2] - box[0] + 8)
    image = Image.new("RGBA", (width, 14), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width - 1, 13], fill=(14, 11, 9, 255))
    draw.text((4, 2), text, font=font, fill=PAPER)
    return image


# ---------------------------------------------------------------------------
# the nano-banana sheets
# ---------------------------------------------------------------------------
def key_out(sheet: Image.Image, tolerance: int = 70) -> Image.Image:
    """Flood the flat green backdrop to transparent from the image border.

    Gemini does not return alpha, and the "pure green" asked for comes back as
    SOME green with a tinted edge — so the backdrop colour is taken as the
    median of the border, and the fill starts at the border so green accents
    INSIDE a character survive.
    """
    sheet = sheet.convert("RGBA")
    width, height = sheet.size
    pixels = sheet.load()
    border = []
    for x in range(width):
        border.append(pixels[x, 0][:3])
        border.append(pixels[x, height - 1][:3])
    for y in range(height):
        border.append(pixels[0, y][:3])
        border.append(pixels[width - 1, y][:3])
    reds = sorted(c[0] for c in border)
    greens = sorted(c[1] for c in border)
    blues = sorted(c[2] for c in border)
    key = (reds[len(reds) // 2], greens[len(greens) // 2], blues[len(blues) // 2])

    def near(colour) -> bool:
        return (abs(colour[0] - key[0]) + abs(colour[1] - key[1]) +
                abs(colour[2] - key[2])) <= tolerance

    stack = []
    for x in range(width):
        stack.append((x, 0))
        stack.append((x, height - 1))
    for y in range(height):
        stack.append((0, y))
        stack.append((width - 1, y))
    seen = bytearray(width * height)
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        seen[index] = 1
        colour = pixels[x, y]
        if not near(colour):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        stack.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
    return sheet


def split_columns(sheet: Image.Image, parts: int) -> list[Image.Image]:
    """Split a keyed row on its emptiest columns, then trim each part."""
    width, height = sheet.size
    alpha = sheet.split()[3]
    counts = [sum(1 for y in range(height) if alpha.getpixel((x, y)) > 8)
              for x in range(width)]
    spans, start = [], None
    for x, count in enumerate(counts):
        if count > 2 and start is None:
            start = x
        elif count <= 2 and start is not None:
            if x - start > width // 40:
                spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, width))
    if len(spans) != parts:
        # Fall back to equal thirds; the trim below still centres each cog.
        step = width // parts
        spans = [(i * step, (i + 1) * step) for i in range(parts)]
    out = []
    for x0, x1 in spans[:parts]:
        part = sheet.crop((x0, 0, x1, height))
        box = part.getbbox()
        out.append(part.crop(box) if box else part)
    return out


def fit(image: Image.Image, width: int, height: int) -> Image.Image:
    """Contain-fit into a transparent box, anchored at the bottom (the feet)."""
    scale = min(width / image.width, height / image.height)
    size = (max(1, int(image.width * scale)), max(1, int(image.height * scale)))
    scaled = image.resize(size, Image.LANCZOS)
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    out.paste(scaled, ((width - size[0]) // 2, height - size[1]), scaled)
    return out


def tint(image: Image.Image, colour) -> Image.Image:
    """A ground ellipse under the wheels in the seat's body colour.

    A ring around the BODY would hide the kit (the wrench, the oil can, the
    override lever), which is the whole point of one kit per role — so the
    slot tint goes under the feet instead (raid's rule, art playbook step 3).
    """
    out = image.copy()
    draw = ImageDraw.Draw(out)
    width, height = out.size
    draw.ellipse([width // 2 - 13, height - 8, width // 2 + 13, height - 1],
                 fill=colour + (255,))
    return out


def carry_pose(front: Image.Image, colour) -> Image.Image:
    """The carrying pose: the same body with both arms raised as a cradle.

    The carried cube is drawn as its own sprite OVER THE HEAD by the viewer, so
    the pose only has to read as "hands up".
    """
    out = front.copy()
    draw = ImageDraw.Draw(out)
    width = out.size[0]
    # Two short forearms raised outside the shoulders. Kept clear of the screen
    # face and of the head silhouette, so the cog still reads as the same cog.
    for x0 in (3, width - 8):
        draw.rectangle([x0, 16, x0 + 4, 27], fill=colour + (255,), outline=INK)
        draw.rectangle([x0 - 1, 12, x0 + 5, 17], fill=(210, 214, 220, 255), outline=INK)
    return out


def cogs() -> None:
    sheet = key_out(Image.open(os.path.join(SOURCE, "cogs_sheet.png")))
    parts = split_columns(sheet, 3)
    for part, slot in zip(parts, ["red", "blue", "yellow"]):
        front = tint(fit(part, 36, 48), SEAT_TINT[slot])
        save(front, os.path.join(DATA, f"cog_{slot}_front.png"))
        save(carry_pose(front, SEAT_TINT[slot]), os.path.join(DATA, f"cog_{slot}_carry.png"))


def lockerroom() -> None:
    bg = Image.open(os.path.join(SOURCE, "lockerroom_bg.png")).convert("RGB")
    bg = bg.resize((992, 926), Image.LANCZOS)
    os.makedirs(LOCKER, exist_ok=True)
    bg.save(os.path.join(LOCKER, "bg.jpg"), quality=88, optimize=True)
    print(f"  {os.path.relpath(os.path.join(LOCKER, 'bg.jpg'), ROOT)}  992x926")
    sheet = key_out(Image.open(os.path.join(SOURCE, "portraits_sheet.png")))
    # The inherited `#lockerroom` markup and its `buildLockerRoom()` carousel
    # ship UNCHANGED (they are on the design note's keep list), and that script
    # asks for <bot>_<pose>.webp with poses 1, 2, 3, 5, 6 for four bot colours.
    # Factory Commons has THREE cogs, so the three seat colours get the three
    # nano-banana portraits with a small per-pose bob (a carousel of five
    # identical frames would read as a freeze) and `green` — which is not a
    # seat here — ships a 1x1 transparent plate so the fourth carousel is
    # simply not there. No edit to the starter's script.
    for part, slot in zip(split_columns(sheet, 3), ["red", "blue", "yellow"]):
        portrait = fit(part, 180, 174)
        for pose, bob in zip([1, 2, 3, 5, 6], [0, 2, 4, 2, 6]):
            frame = Image.new("RGBA", (180, 174), (0, 0, 0, 0))
            frame.paste(portrait, (0, -bob), portrait)
            path = os.path.join(LOCKER, f"{slot}_{pose}.webp")
            binarize(frame).save(path, lossless=True)
            print(f"  {os.path.relpath(path, ROOT)}  180x174")
    blank = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    for pose in [1, 2, 3, 5, 6]:
        path = os.path.join(LOCKER, f"green_{pose}.webp")
        blank.save(path, lossless=True)
    print(f"  {os.path.relpath(os.path.join(LOCKER, 'green_*.webp'), ROOT)}  1x1 (no fourth cog)")


# ---------------------------------------------------------------------------
def main() -> None:
    os.makedirs(DATA, exist_ok=True)
    print("plant:")
    save(floor_steel(), os.path.join(DATA, "floor_steel.png"))
    save(wall_panel(False), os.path.join(DATA, "wall_panel_h.png"))
    save(wall_panel(True), os.path.join(DATA, "wall_panel_v.png"))
    for state in ["prime", "worn", "failing", "scrap"]:
        save(machine(state), os.path.join(DATA, f"machine_{state}.png"))
    save(console(), os.path.join(DATA, "console.png"))
    save(lever("cycle"), os.path.join(DATA, "lever_cycle.png"))
    save(lever("override"), os.path.join(DATA, "lever_override.png"))
    save(bay(), os.path.join(DATA, "bay.png"))
    save(funnel(PINK, True), os.path.join(DATA, "dispenser_pink.png"))
    save(funnel(BLUE, True), os.path.join(DATA, "dispenser_blue.png"))
    save(funnel(PINK, False), os.path.join(DATA, "hopper_pink.png"))
    save(funnel(BLUE, False), os.path.join(DATA, "hopper_blue.png"))
    save(belt_seg(), os.path.join(DATA, "belt_seg.png"))
    save(belt_chevron(), os.path.join(DATA, "belt_chevron.png"))
    save(chute(), os.path.join(DATA, "chute.png"))
    save(cube(PINK, True), os.path.join(DATA, "cube_pink.png"))
    save(cube(BLUE, False), os.path.join(DATA, "cube_blue.png"))
    save(banana(), os.path.join(DATA, "banana.png"))
    save(effect("press"), os.path.join(DATA, "press_flash.png"))
    save(effect("strip"), os.path.join(DATA, "strip_smoke.png"))
    for alias in ["BOLT", "COTTER", "RATCHET"]:
        save(label(alias), os.path.join(DATA, f"label_{alias.lower()}.png"))
    print("cogs (nano-banana):")
    cogs()
    print("locker room (nano-banana):")
    lockerroom()


if __name__ == "__main__":
    main()
